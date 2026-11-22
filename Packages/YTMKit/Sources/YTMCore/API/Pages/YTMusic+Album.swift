import Foundation

extension YTMusic {
    func albumPage(_ id: String) async throws -> Page {
        // As the account sees it, for whether it is saved.
        let response = try await asAccount(true) { try await self.innerTube.browse(id, authenticated: $0) }.response
        var album = try Renderers.album(response, id: id)
        // YouTube Music lists some album tracks by their music videos and
        // cuts long albums short; the album's playlist has the songs and the rest.
        if let playlistId = album.playlistId, album.needsPlaylist,
           let songs = try? await playlistTracks(playlistId, limit: album.trackCount, asOwner: false) {
            album.adopt(songs)
        }
        try Task.checkCancellation()
        return album.page
    }
}

struct AlbumDetails {
    var ref: AlbumRef
    var type: AlbumType
    var artists: [ArtistRef]
    var year: Int?
    var description: String?
    var cover: JSON
    var playlistId: String?
    /// Whether the account has it in its library; unknown signed out.
    var saved: Bool?
    /// How many tracks the header says the album has.
    var trackCount: Int
    var tracks: [Track]
    var versions: Section?

    var needsPlaylist: Bool {
        tracks.contains(where: \.isVideo) || (tracks.last?.trackNumber ?? 0) < trackCount
    }

    /// Swaps each music video for the playlist's song of the same title, and adds the
    /// playlist's tracks beyond the album's, numbered on.
    mutating func adopt(_ playlist: [Track]) {
        for index in tracks.indices where tracks[index].isVideo {
            guard let song = playlist.first(where: { !$0.isVideo && $0.title == tracks[index].title }) else { continue }
            tracks[index].id = song.id
            tracks[index].duration = song.duration ?? tracks[index].duration
            tracks[index].isVideo = false
        }
        var number = tracks.last?.trackNumber ?? 0
        for var track in playlist.dropFirst(tracks.count) {
            number += 1
            track.album = ref
            track.trackNumber = number
            tracks.append(track)
        }
    }

    /// Album tracks come without artwork, so they show the cover.
    var page: Page {
        let rowCover = Thumbnail.pick(cover, edge: Thumbnail.row)
        let tracks = tracks.map { track in
            var track = track
            track.thumbnail = track.thumbnail ?? rowCover
            track.album = track.album ?? ref
            return track
        }
        let meta = [year.map(String.init), Formatting.songs(tracks.count), Formatting.totalTime(tracks)]
        var header = PageHeader(
            label: type.label,
            title: ref.name,
            subtitle: ArtistRef.joined(artists),
            meta: meta.compactMap(\.self).joined(separator: " • "),
            description: description,
            thumbnail: Thumbnail.pick(cover, edge: Thumbnail.header),
            radioId: playlistId.map(YTMusic.radioId(forPlaylist:)),
            playlistId: playlistId
        )
        header.saved = saved
        let list = Section.tracks(TrackSection(title: "", tracks: tracks, mode: .section, numbered: true))
        return Page(header: header, sections: [list] + [versions].compactMap(\.self))
    }
}

extension Renderers {
    static func album(_ response: JSON, id: String) throws -> AlbumDetails {
        let header = detailHeader(in: response)
        guard let title = header["title"].text, !title.isEmpty else {
            throw YTMError(.notFound, "This album isn't available.")
        }
        let subtitle = segments(header["subtitle"].runs)
        let strapline = header["straplineTextOne"].runs
        // "Album • 2021" with the artists in the strapline, or, in the older
        // layout, "Album • Artist • 2021", "Album • 2021" or "Album • Artist".
        var yearRuns: [JSON]?
        var artistRuns: [JSON]? = strapline.isEmpty ? nil : strapline
        switch (strapline.isEmpty, subtitle.count) {
        case (false, 2...): yearRuns = subtitle[1]
        case (true, 3...): (artistRuns, yearRuns) = (subtitle[1], subtitle[2])
        case (true, 2) where text(subtitle[1]).allSatisfy(\.isASCIIDigit): yearRuns = subtitle[1]
        case (true, 2): artistRuns = subtitle[1]
        default: break
        }
        let artists = artistRuns.map { runs -> [ArtistRef] in
            let linked = linkedArtists(runs)
            return linked.isEmpty ? unlinkedArtists([runs]) : linked
        } ?? []

        let ref = AlbumRef(id: id, name: title)
        let context = ItemContext(album: ref, artists: artists)
        var tracks = trackShelf(in: response)["contents"].array.compactMap { row -> Track? in
            let renderer = row["musicResponsiveListItemRenderer"]
            guard var track = track(renderer, context: context) else { return nil }
            // A row leaves its artists' column empty when they are the
            // album's; the plays in the column after it name no one.
            if columnText(renderer["flexColumns"][1]).runs.isEmpty { track.artists = artists }
            return track
        }
        // A few albums number some tracks 0; those follow on from the one before.
        var previous = 0
        for index in tracks.indices {
            if let number = tracks[index].trackNumber, number > 0 {
                previous = number
            } else {
                previous += 1
                tracks[index].trackNumber = previous
            }
        }

        return AlbumDetails(
            ref: ref,
            type: subtitle.first.flatMap { AlbumType(label: text($0)) } ?? .album,
            artists: artists,
            year: yearRuns?.first?["text"].string.flatMap(Formatting.number),
            description: description(header),
            cover: Thumbnail.list(in: header),
            playlistId: albumPlaylistId(response, header: header),
            saved: saved(header),
            trackCount: trackCount(header) ?? tracks.count,
            tracks: tracks,
            versions: sectionList(in: response)["contents"].array.lazy
                .filter { $0["musicCarouselShelfRenderer", "header", "musicCarouselShelfBasicHeaderRenderer", "title"].text == "Other versions" }
                .compactMap { section($0, layout: .carousel) }.first
        )
    }

    private static func albumPlaylistId(_ response: JSON, header: JSON) -> String? {
        let prefix = "https://music.youtube.com/playlist?list="
        if let url = response["microformat", "microformatDataRenderer", "urlCanonical"].string, url.hasPrefix(prefix) {
            return String(url.dropFirst(prefix.count))
        }
        let menus = (header["buttons"].array + [header["menu"]]).map { $0["menuRenderer"] }
        let endpoints = menus.flatMap { menu in
            menu["topLevelButtons"].array.map { $0["buttonRenderer", "navigationEndpoint"] }
                + menu["items"].array.map { $0["menuNavigationItemRenderer", "navigationEndpoint"] }
        }
        return endpoints.lazy.compactMap { $0["watchPlaylistEndpoint", "playlistId"].string }.first
    }
}
