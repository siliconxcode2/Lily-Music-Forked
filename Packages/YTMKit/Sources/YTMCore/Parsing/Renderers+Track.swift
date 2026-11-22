import Foundation

extension Renderers {
    /// A song or video from a `musicResponsiveListItemRenderer`'s body; nil for
    /// rows that open a page, live streams, and rows without an ID or title.
    static func track(_ renderer: JSON, context: ItemContext = ItemContext()) -> Track? {
        if renderer["navigationEndpoint", "browseEndpoint"].exists { return nil }
        let badges = renderer["badges"].array
        if badges.contains(where: { $0["liveBadgeRenderer"].exists }) { return nil }

        let columns = renderer["flexColumns"].array.map(columnText)
        guard let titleRuns = columns.first?.runs, let title = columns.first?.text, !title.isEmpty else { return nil }
        let playButton = renderer["overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint", "watchEndpoint"]
        let watch = playButton.exists ? playButton : titleRuns.first?["navigationEndpoint", "watchEndpoint"] ?? .missing
        guard let id = renderer["playlistItemData", "videoId"].string ?? watch["videoId"].string, !id.isEmpty else { return nil }

        // The details are found by their links and shapes rather than their
        // column order, which differs between lists.
        let details = columns.dropFirst().flatMap(\.runs)
        let segments = columns.dropFirst().flatMap { Renderers.segments($0.runs) }
        var artists = linkedArtists(details)
        if artists.isEmpty { artists = unlinkedArtists(segments) }
        if artists.isEmpty { artists = context.artists }
        let fixed = renderer["fixedColumns"][0]
        let duration = columnText(fixed).text.flatMap(Formatting.seconds)
            ?? segments.lazy.compactMap { Formatting.seconds(text($0)) }.last

        let thumbnails = Thumbnail.list(in: renderer)
        // Without a video type, a wide thumbnail means a video; album tracks are songs.
        let first = thumbnails[0]
        let isVideo = isVideo(watch, context: context) ?? (context.album == nil && first.exists && first["width"].int != first["height"].int)

        var track = Track(
            id: id,
            title: title,
            artists: artists,
            album: album(details) ?? context.album,
            duration: duration,
            thumbnail: Thumbnail.pick(thumbnails, edge: Thumbnail.row),
            trackNumber: renderer["index"].text.flatMap { Int($0) },
            isVideo: isVideo
        )
        if context.entries { track.setVideoId = renderer["playlistItemData", "playlistSetVideoId"].string }
        return track
    }

    static func columnText(_ column: JSON) -> JSON {
        column.first("musicResponsiveListItemFlexColumnRenderer", "musicResponsiveListItemFixedColumnRenderer")["text"]
    }
}
