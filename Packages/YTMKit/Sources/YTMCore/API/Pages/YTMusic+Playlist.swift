import Foundation

extension YTMusic {
    static let playlistLimit = 500

    /// The first batch; `loadMore` adds the rest, up to `playlistLimit`.
    func playlistPage(_ id: String) async throws -> Page {
        try Renderers.playlistPage(try await playlistResponse(id, asOwner: true), id: id)
    }

    /// A batch that fails ends the list with what arrived, unless `whole`, when it throws instead.
    func playlistTracks(_ id: String, limit: Int, asOwner: Bool, whole: Bool = false) async throws -> [Track] {
        let shelf = Renderers.trackShelf(in: try await playlistResponse(id, asOwner: asOwner))
        var seen = Set<String>()
        var (tracks, fetched) = Renderers.playlistRows(shelf["contents"].array, seen: &seen)
        var token = Renderers.continuation(shelf)
        while let current = token, fetched < limit {
            guard let batch = try await playlistBatch(after: current, asOwner: asOwner, seen: &seen) else {
                if whole { throw YTMError(.network, "The whole playlist couldn't be loaded.") }
                break
            }
            guard batch.fetched > 0 else { break }
            tracks += batch.tracks
            fetched += batch.fetched
            token = batch.next
        }
        return tracks
    }

    /// Nil when the batch failed for any reason but cancellation. Leaves out the entries `seen` holds, as
    /// `Renderers.playlistRows` does; `fetched` counts them too.
    func playlistBatch(
        after token: String, asOwner: Bool, entries: Bool = false, seen: inout Set<String>
    ) async throws -> (tracks: [Track], fetched: Int, next: String?)? {
        do {
            let response = try await asAccount(asOwner) { try await self.innerTube.continuation(token, authenticated: $0) }.response
            let (items, next) = Renderers.continuationItems(in: response)
            let batch = Renderers.playlistRows(items, entries: entries, seen: &seen)
            return (batch.tracks, batch.fetched, next)
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    private func playlistResponse(_ id: String, asOwner: Bool) async throws -> JSON {
        try await asAccount(asOwner) { try await self.innerTube.browse("VL" + id, authenticated: $0) }.response
    }

    /// With `asOwner`, asks as the account, then signed out should that fail, so a stale cookie still opens public
    /// pages; the first failure is reported. `signedIn` says whether the answer really was the account's.
    func asAccount(_ asOwner: Bool, _ request: (Bool) async throws -> JSON) async throws -> (response: JSON, signedIn: Bool) {
        guard asOwner else { return (try await request(false), false) }
        let signedIn = await auth.isSignedIn
        do {
            let response = try await request(true)
            return (response, signedIn && !Renderers.answeredSignedOut(response))
        } catch {
            try Task.checkCancellation()
            guard await auth.isSignedIn, let signedOut = try? await request(false) else { throw error }
            return (signedOut, false)
        }
    }
}

extension Renderers {
    static func playlistPage(_ response: JSON, id: String) throws -> Page {
        let header = detailHeader(in: response)
        let shelf = trackShelf(in: response)
        guard header.exists || shelf.exists else {
            throw YTMError(.notFound, "This playlist isn't available.")
        }
        let ownership = ownership(in: response)
        // Only those the account made take edits, not Liked music or the mixes.
        let own = ownership.editable && id.hasPrefix("PL")
        var seen = Set<String>()
        let (tracks, fetched) = playlistRows(shelf["contents"].array, entries: own, seen: &seen)
        let token = continuation(shelf)
        // The whole list's count is worth reading only when this batch isn't all of it.
        let count = token == nil ? tracks.count : trackCount(header)
        var pageHeader = PageHeader(
            label: "Playlist",
            // Album playlists can come without a header; their tracks name the album.
            title: header["title"].text ?? tracks.first?.album?.name ?? "",
            subtitle: playlistOwner(header) ?? "",
            meta: Formatting.playlistMeta(count: count, tracks: tracks),
            description: description(header),
            thumbnail: Thumbnail.pick(Thumbnail.list(in: header), edge: Thumbnail.header),
            radioId: YTMusic.radioId(forPlaylist: id),
            playlistId: id
        )
        pageHeader.count = count
        if own {
            pageHeader.editable = true
            pageHeader.privacy = ownership.privacy
        }
        pageHeader.saved = saved(header)
        return Page(
            header: pageHeader,
            sections: [Section.tracks("", tracks, mode: .section)].compactMap(\.self),
            more: token.flatMap { tracks.isEmpty ? nil : .tracks(token: $0, seen: seen, fetched: fetched) }
        )
    }

    /// Drops the entries `seen` already holds and adds the rest: YouTube sometimes answers a long playlist's next
    /// batch from its start again. By entry, not song, so a song listed twice keeps both. `fetched` counts the
    /// repeats too; `entries` keeps entry IDs, for the account's own playlist.
    static func playlistRows(_ items: [JSON], entries: Bool = false, seen: inout Set<String>) -> (tracks: [Track], fetched: Int) {
        let rows = items.filter {
            $0["musicResponsiveListItemRenderer", "playlistItemData", "playlistSetVideoId"].string.map { seen.insert($0).inserted } ?? true
        }
        let tracks = tracks(rows, context: ItemContext(entries: entries))
        return (tracks, tracks.count + items.count - rows.count)
    }

    /// `page` with a later batch from `YTMusic.playlistBatch` and the next step, if one is due. A batch of only
    /// repeats carries on, as the next may hold new songs. `fetched`, the tracks before this batch with repeats,
    /// counts towards `YTMusic.playlistLimit`.
    static func addingBatch(
        _ batch: (tracks: [Track], fetched: Int, next: String?), to page: Page, seen: Set<String>, fetched: Int
    ) -> Page {
        var page = page
        page.more = nil
        guard case .tracks(var section)? = page.sections.first else { return page }
        section.tracks += batch.tracks
        page.sections[0] = .tracks(section)
        let total = fetched + batch.fetched
        if let next = batch.next, batch.fetched > 0, total < YTMusic.playlistLimit {
            page.more = .tracks(token: next, seen: seen, fetched: total)
        }
        if page.header != nil {
            // The header counts the whole playlist when YouTube said how
            // long it is, else the tracks loaded.
            let count = max(page.header?.count ?? 0, section.tracks.count)
            page.header?.count = count
            page.header?.meta = Formatting.playlistMeta(count: count, tracks: section.tracks)
        }
        return page
    }

    /// The channel the facepile links to, else the one in the strapline or
    /// subtitle. YouTube Music's own playlists name none.
    private static func playlistOwner(_ header: JSON) -> String? {
        let facepile = header["facepile", "avatarStackViewModel"]
        guard facepile.exists else {
            return linkedArtists(header.first("straplineTextOne", "subtitle").runs).first?.name
        }
        let onTap = facepile["rendererContext", "commandContext", "onTap", "innertubeCommand"]
        guard case (.artist, _)? = page(onTap) else { return nil }
        return facepile["text", "content"].string
    }
}
