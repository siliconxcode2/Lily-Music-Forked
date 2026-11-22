import Foundation

extension YTMusic {
    /// Asked as the account when signed in, so private playlists' radios play.
    @concurrent
    public func radio(playlistId: String) async throws -> [Track] {
        let next = try await innerTube.next(["playlistId": playlistId, "params": Self.radioParams], authenticated: true)
        return try Renderers.queue(in: next)
    }

    /// 50 tracks, without the song itself, which callers queue first.
    @concurrent
    public func radio(videoId: String) async throws -> [Track] {
        let next = try await innerTube.next(["playlistId": "RDAMVM" + videoId, "params": Self.radioParams], authenticated: false)
        return try Renderers.queue(in: next)
    }

    public static func radioId(forPlaylist id: String) -> String { "RDAMPL" + id }

    /// The params YouTube Music's player starts a radio with.
    private static let radioParams = "wAEB8gECeAE%3D"
}

extension InnerTube {
    func next(_ target: [String: String], authenticated: Bool) async throws -> JSON {
        var body: [String: Any] = [
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]
        body.merge(target) { $1 }
        return try await post("next", body: body, authenticated: authenticated)
    }
}

extension Renderers {
    static func watchNextTabs(_ next: JSON) -> [JSON] {
        next["contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer", "watchNextTabbedResultsRenderer", "tabs"]
            .array.map { $0["tabRenderer"] }
    }

    /// Fails when there is no queue, which is how YouTube answers for a radio
    /// it can't make.
    static func queue(in next: JSON) throws -> [Track] {
        guard let panel = watchNextTabs(next).lazy
            .map({ $0["content", "musicQueueRenderer", "content", "playlistPanelRenderer"] })
            .first(where: \.exists)
        else { throw YTMError(.notFound, "YouTube has no radio for this.") }
        return panel["contents"].array.compactMap { item in
            // Signed in, a song with a music video comes wrapped with it;
            // the song is the primary one.
            let direct = item["playlistPanelVideoRenderer"]
            return queueTrack(direct.exists ? direct : item["playlistPanelVideoWrapperRenderer", "primaryRenderer", "playlistPanelVideoRenderer"])
        }
    }

    /// The byline's first part names the artists and, for songs, the second
    /// the album.
    static func queueTrack(_ renderer: JSON) -> Track? {
        guard let id = renderer["videoId"].string, !id.isEmpty,
              let title = renderer["title"].text, !title.isEmpty
        else { return nil }
        let segments = segments(renderer["longBylineText"].runs)
        let byline = segments.first ?? []
        var artists = linkedArtists(byline)
        if artists.isEmpty { artists = unlinkedArtists([byline]) }

        let thumbnails = renderer["thumbnail", "thumbnails"]
        let first = thumbnails[0]
        // Without a video type, videos show by their wide thumbnails, and an
        // item without any counts as one.
        let isVideo = isVideo(renderer["navigationEndpoint", "watchEndpoint"])
            ?? !(first.exists && first["width"].int == first["height"].int)

        return Track(
            id: id,
            title: title,
            artists: artists,
            album: isVideo ? nil : segments.dropFirst().first.flatMap(album),
            duration: renderer["lengthText"].text.flatMap(Formatting.seconds),
            thumbnail: Thumbnail.pick(thumbnails, edge: Thumbnail.row),
            isVideo: isVideo
        )
    }
}
