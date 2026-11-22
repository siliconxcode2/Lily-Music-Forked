import Foundation

extension YTMusic {
    /// Songs or actions YouTube takes in one playlist call.
    private static let perRequest = 100

    @concurrent
    public func rating(videoId: String) async throws -> Rating {
        guard await auth.isSignedIn else { return .none }
        return Rating(next: try await innerTube.post("next", body: ["videoId": try Self.videoId(videoId)]))
    }

    @concurrent
    public func rate(videoId: String, _ rating: Rating) async throws {
        let endpoint = switch rating {
        case .like: "like/like"
        case .dislike: "like/dislike"
        case .none: "like/removelike"
        }
        _ = try await edit(endpoint, ["target": ["videoId": try Self.videoId(videoId)]])
    }

    @concurrent
    public func playlists(adding videoId: String) async throws -> [PlaylistOption] {
        let reply = try await edit("playlist/get_add_to_playlist", ["videoIds": [try Self.videoId(videoId)]])
        guard let options = PlaylistOption.list(in: reply) else {
            throw YTMError(.parse, "YouTube didn't list your playlists.")
        }
        return options
    }

    @concurrent
    public func addToPlaylist(_ playlistId: String, videoIds: [String]) async throws {
        let actions = try videoIds.map { ["action": "ACTION_ADD_VIDEO", "addedVideoId": try Self.videoId($0)] }
        try await editPlaylist(playlistId, actions: actions)
    }

    /// The create call takes only so many songs, so the rest are added after.
    @concurrent
    public func createPlaylist(title: String, videoIds: [String]) async throws -> String {
        let videoIds = try videoIds.map(Self.videoId)
        let first = Array(videoIds.prefix(Self.perRequest))
        let created = try await edit("playlist/create", ["title": title, "privacyStatus": "PRIVATE", "videoIds": first], retries: 0)
        guard let id = created["playlistId"].string, !id.isEmpty else {
            throw YTMError(.parse, "YouTube didn't return the new playlist.")
        }
        try await addToPlaylist(id, videoIds: Array(videoIds.dropFirst(first.count)))
        return id
    }

    /// Removes `tracks`, as its page has them, from one of the account's playlists.
    @concurrent
    public func removeFromPlaylist(_ playlistId: String, tracks: [Track]) async throws {
        let actions = try tracks.map { track in
            guard let entry = track.setVideoId else { throw YTMError(.refused, "The song isn't in your playlist.") }
            return ["action": "ACTION_REMOVE_VIDEO", "setVideoId": try Self.youtubeId(entry), "removedVideoId": try Self.videoId(track.id)]
        }
        try await editPlaylist(playlistId, actions: actions)
    }

    /// Moves the entry of one of the account's playlists to before the entry `before`, or last.
    @concurrent
    public func moveInPlaylist(_ playlistId: String, entry: String, before: String?) async throws {
        var action = ["action": "ACTION_MOVE_VIDEO_BEFORE", "setVideoId": try Self.youtubeId(entry)]
        // Without a successor YouTube moves it last (ytmusicapi's edit_playlist).
        if let before { action["movedSetVideoIdSuccessor"] = try Self.youtubeId(before) }
        try await editPlaylist(playlistId, actions: [action])
    }

    @concurrent
    public func renamePlaylist(_ playlistId: String, title: String) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw YTMError(.refused, "A playlist needs a name.") }
        try await editPlaylist(playlistId, actions: [["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": title]])
    }

    @concurrent
    public func setPrivacy(_ privacy: PlaylistPrivacy, ofPlaylist playlistId: String) async throws {
        try await editPlaylist(playlistId, actions: [["action": "ACTION_SET_PLAYLIST_PRIVACY", "playlistPrivacy": privacy.rawValue]])
    }

    @concurrent
    public func deletePlaylist(_ playlistId: String) async throws {
        try Self.performed(try await edit("playlist/delete", ["playlistId": try Self.youtubeId(playlistId)]))
    }

    /// Saves an album or playlist to the library, by the playlist ID its header carries, or removes it.
    @concurrent
    public func setSaved(_ saved: Bool, playlistId: String) async throws {
        let target = ["target": ["playlistId": try Self.youtubeId(playlistId)]]
        try Self.performed(try await edit(saved ? "like/like" : "like/removelike", target))
    }

    /// Subscribes to an artist by the channel its header carries, or unsubscribes.
    @concurrent
    public func setSubscribed(_ subscribed: Bool, channelId: String) async throws {
        let channels = ["channelIds": [try Self.youtubeId(channelId)]]
        try Self.performed(try await edit(subscribed ? "subscription/subscribe" : "subscription/unsubscribe", channels))
    }

    /// A refused edit, such as one to a full playlist, still answers 200, so
    /// each reply's status is checked.
    private func editPlaylist(_ playlistId: String, actions: [[String: String]]) async throws {
        let playlistId = try Self.youtubeId(playlistId)
        for start in stride(from: 0, to: actions.count, by: Self.perRequest) {
            let chunk = Array(actions[start..<min(start + Self.perRequest, actions.count)])
            let reply = try await edit("browse/edit_playlist", ["playlistId": playlistId, "actions": chunk])
            guard Self.succeeded(reply) else { throw Self.playlistRefusal(reply) }
        }
    }

    static func succeeded(_ reply: JSON) -> Bool {
        reply["status"].string == "STATUS_SUCCEEDED"
    }

    /// An account without a channel is asked to make one before it can share a playlist.
    static func playlistRefusal(_ reply: JSON) -> YTMError {
        reply.contains(key: "channelCreationFormEndpoint")
            ? YTMError(.refused, "The account needs a YouTube channel to share playlists.")
            : YTMError(.refused, "YouTube didn't change the playlist.")
    }

    /// For answers without a status: a change YouTube held back comes with a dialog instead (ytmusicapi's
    /// validate_write_response).
    static func performed(_ reply: JSON) throws {
        if reply["actions"][0]["showEngagementPanelEndpoint"].exists {
            throw YTMError(.refused, "YouTube didn't make the change.")
        }
    }

    /// Throws unless `id` looks like a playlist, channel or entry ID, so nothing else reaches an edit request.
    static func youtubeId(_ id: String) throws -> String {
        guard (1...64).contains(id.utf8.count), isIdText(id) else { throw YTMError(.parse, "That isn't a YouTube ID.") }
        return id
    }

    /// `id`, should it be a video's, so no other ID ever goes in as a song.
    static func videoId(_ id: String) throws -> String {
        guard id.utf8.count == 11, isIdText(id) else { throw YTMError(.parse, "That isn't a YouTube song.") }
        return id
    }

    private static func isIdText(_ id: String) -> Bool {
        id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }
    }

    /// Creating passes `retries` 0, as a timed-out create YouTube carried out would make a second playlist.
    private func edit(_ endpoint: String, _ body: [String: Any], retries: Int = InnerTube.retries) async throws -> JSON {
        guard await auth.isSignedIn else {
            throw YTMError(.notSignedIn, "Sign in to change your library.")
        }
        return try await innerTube.post(endpoint, body: body, retries: retries)
    }
}

extension Rating {
    init(next: JSON) {
        let status = next["playerOverlays", "playerOverlayRenderer", "actions"][0]["likeButtonRenderer", "likeStatus"].string
        self = status.flatMap(Rating.init(rawValue:)) ?? .none
    }
}

extension PlaylistOption {
    /// Nil when the reply holds no list.
    static func list(in reply: JSON) -> [PlaylistOption]? {
        let playlists = reply["contents"][0]["addToPlaylistRenderer", "playlists"]
        guard playlists.isArray else { return nil }
        return playlists.array.compactMap { item in
            let option = item["playlistAddToOptionRenderer"]
            guard let id = option["playlistId"].string, let title = option["title"].text else { return nil }
            return PlaylistOption(
                id: id,
                title: title,
                thumbnail: Thumbnail.pick(option["thumbnail", "thumbnails"], edge: Thumbnail.row),
                contains: option["containsSelectedVideos"].string == "ALL"
            )
        }
    }
}
