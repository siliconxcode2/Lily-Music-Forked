import Foundation

extension YTMusic {
    /// What playing a card queues; for an artist, its top songs without the
    /// discography the page fetches.
    @concurrent
    public func tracks(of card: Card) async throws -> [Track] {
        switch card.kind {
        case .album: try await albumPage(card.id).headerTracks
        case .playlist: try await playlistTracks(card.id)
        case .artist: try await artist(card.id).songs
        case .genre, .song: []
        }
    }

    @concurrent
    public func playlistTracks(_ playlistId: String) async throws -> [Track] {
        try await playlistTracks(playlistId, limit: Self.playlistLimit, asOwner: true)
    }

    /// Throws rather than end short, so a downloaded playlist kept in step never loses songs to a bad connection.
    @concurrent
    public func wholePlaylistTracks(_ playlistId: String) async throws -> [Track] {
        try await playlistTracks(playlistId, limit: Self.playlistLimit, asOwner: true, whole: true)
    }

    /// Found by title and artists. Uploads, such as slowed or sped-up edits,
    /// have none.
    @concurrent
    public func songVersion(of video: Track) async throws -> Track? {
        guard case .tracks(let found)? = try await search("\(video.title) \(video.artistNames)", .songs) else { return nil }
        return found.tracks.first { !$0.isVideo && Self.isSongVersion(of: video, $0) }
    }

    @concurrent
    public func suggestions(for query: String) async -> [String] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty,
              let response = try? await innerTube.post("music/get_search_suggestions", body: ["input": query], authenticated: false)
        else { return [] }
        return Renderers.suggestions(in: response)
    }

    /// Only the same title by one of the same artists counts, so an edit is
    /// never swapped for the original or a namesake by someone else.
    static func isSongVersion(of video: Track, _ song: Track) -> Bool {
        func folded(_ title: String) -> String { title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func same(_ a: ArtistRef, _ b: ArtistRef) -> Bool {
            if let id = a.id, id == b.id { return true }
            // Only ASCII letters fold.
            return a.name.utf8.elementsEqual(b.name.utf8) { asciiLower($0) == asciiLower($1) }
        }
        return folded(song.title) == folded(video.title)
            && song.artists.contains { s in video.artists.contains { same(s, $0) } }
    }

    private static func asciiLower(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte | 0x20 : byte
    }
}

extension Renderers {
    static func suggestions(in response: JSON) -> [String] {
        response["contents"].array.flatMap { section in
            section["searchSuggestionsSectionRenderer", "contents"].array.compactMap {
                $0["searchSuggestionRenderer", "suggestion"].text.flatMap { $0.isEmpty ? nil : $0 }
            }
        }
    }
}
