import Foundation

extension Renderers {
    /// A `musicTwoRowItemRenderer`'s body: a page tile, or a song tile that plays.
    static func twoRowCard(_ renderer: JSON, context: ItemContext = ItemContext()) -> Card? {
        guard let title = renderer["title"].text, !title.isEmpty else { return nil }
        let subtitle = renderer["subtitle"].runs
        let thumbnails = Thumbnail.list(in: renderer)
        let endpoint = renderer["navigationEndpoint"]
        let watch = endpoint["watchEndpoint"]
        if let videoId = watch["videoId"].string, !videoId.isEmpty {
            // Genre radios ("Pop radio") have no page or song of their own.
            if watch["playlistId"].string?.hasPrefix("RDQM") == true { return nil }
            var artists = linkedArtists(subtitle)
            if artists.isEmpty { artists = unlinkedArtists(segments(subtitle)) }
            let track = Track(
                id: videoId, title: title, artists: artists,
                thumbnail: Thumbnail.pick(thumbnails, edge: Thumbnail.row),
                isVideo: isVideo(watch, context: context) ?? false
            )
            return Card(
                kind: .song, id: videoId, title: title, subtitle: text(subtitle),
                thumbnail: Thumbnail.pick(thumbnails, edge: Thumbnail.card), track: track
            )
        }
        if let playlistId = endpoint["watchPlaylistEndpoint", "playlistId"].string, !playlistId.isEmpty {
            return Card(
                kind: .playlist, id: playlistId, title: title,
                subtitle: subtitleText(.playlist, subtitle, context: context),
                thumbnail: Thumbnail.pick(thumbnails, edge: Thumbnail.card)
            )
        }
        return pageCard(endpoint, title: title, subtitle: subtitle, thumbnails: thumbnails, context: context)
    }

    /// A `musicResponsiveListItemRenderer`'s body as an album, artist or playlist card.
    static func listCard(_ renderer: JSON, context: ItemContext = ItemContext()) -> Card? {
        let columns = renderer["flexColumns"].array.map(columnText)
        guard let title = columns.first?.text, !title.isEmpty else { return nil }
        let endpoint = renderer["navigationEndpoint"]
        if case (.playlist, let id)? = page(endpoint), BuiltInPlaylist.skippedInLists.contains(id) { return nil }
        let subtitle = columns.dropFirst().first?.runs ?? []
        return pageCard(endpoint, title: title, subtitle: subtitle, thumbnails: Thumbnail.list(in: renderer), context: context)
    }

    /// A `musicCardShelfRenderer`'s top search result, when it is an artist, album or playlist.
    static func topResultCard(_ renderer: JSON) -> Card? {
        guard let title = renderer["title"].text, !title.isEmpty else { return nil }
        return pageCard(
            renderer["onTap"], title: title, subtitle: renderer["subtitle"].runs,
            thumbnails: Thumbnail.list(in: renderer), context: ItemContext()
        )
    }

    /// A mood or genre chip from a `musicNavigationButtonRenderer`'s body;
    /// other navigation buttons (New releases, Charts) are not genres.
    static func genreCard(_ renderer: JSON) -> Card? {
        let browse = renderer["clickCommand", "browseEndpoint"]
        guard browse["browseId"].string == "FEmusic_moods_and_genres_category",
              let params = browse["params"].string, !params.isEmpty,
              let title = renderer["buttonText"].text, !title.isEmpty
        else { return nil }
        // ARGB: the alpha is always opaque, and the model holds RGB.
        let color = renderer["solid", "leftStripeColor"].int.map { UInt32(truncatingIfNeeded: $0) & 0xFF_FFFF }
        return Card(kind: .genre, id: params, title: title, color: color)
    }

    private static func pageCard(
        _ endpoint: JSON, title: String, subtitle: [JSON], thumbnails: JSON, context: ItemContext
    ) -> Card? {
        guard let (page, id) = page(endpoint) else { return nil }
        let kind: CardKind = switch page {
        case .album: .album
        case .artist: .artist
        case .playlist: .playlist
        }
        return Card(
            kind: kind, id: id, title: title, subtitle: subtitleText(kind, subtitle, context: context),
            thumbnail: Thumbnail.pick(thumbnails, edge: Thumbnail.card)
        )
    }

    private static func subtitleText(_ kind: CardKind, _ runs: [JSON], context: ItemContext) -> String {
        guard context.subtitles == .composed else { return text(runs) }
        let segments = segments(runs).map { (runs: $0, text: text($0)) }
        switch kind {
        case .album:
            // "Album • Artist • 2024"; artist pages' tiles say only "2024"
            // or "Album • 2024", and the page's artist stands in.
            let type = segments.lazy.compactMap { AlbumType(label: $0.text) }.first ?? context.albumType
            let year = segments.first { $0.text.count == 4 && Int($0.text) != nil }?.text
            var artists = linkedArtists(runs)
            if artists.isEmpty {
                let names = segments.filter { AlbumType(label: $0.text) == nil && $0.text != year && !typeLabels.contains($0.text) }
                artists = unlinkedArtists(names.map(\.runs))
            }
            if artists.isEmpty { artists = context.artists }
            let names = ArtistRef.joined(artists)
            return [type.label, names.isEmpty ? nil : names, year].compactMap(\.self).joined(separator: " • ")
        case .artist:
            let count = segments.lazy.compactMap { Formatting.count($0.text) }.first
            return count.map { "\(Formatting.compact($0)) subscribers" } ?? "Artist"
        case .playlist:
            // "Playlist • Channel • 12 songs": the count only for YouTube Music's own playlists.
            let channel = linkedArtists(runs).first?.name
            let byYouTube = segments.contains { $0.text.hasPrefix("YouTube") }
            let songs = byYouTube
                ? segments.lazy.filter { $0.text.hasSuffix(" song") || $0.text.hasSuffix(" songs") }
                    .compactMap { Formatting.number($0.text) }.first
                : nil
            return ["Playlist", channel, songs.map(Formatting.songs)].compactMap(\.self).joined(separator: " • ")
        case .genre, .song:
            return text(runs)
        }
    }
}
