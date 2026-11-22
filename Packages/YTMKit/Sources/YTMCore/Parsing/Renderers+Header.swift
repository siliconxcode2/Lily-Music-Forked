import Foundation

extension Renderers {
    /// An album or playlist page's header renderer, from the two-column page's
    /// first tab or else its own header, from inside the wrapper owned playlists add.
    static func detailHeader(in response: JSON) -> JSON {
        for wrapper in headerWrappers(in: response) {
            let editable = wrapper["musicEditablePlaylistDetailHeaderRenderer", "header"]
            let renderer = (editable.exists ? editable : wrapper).first("musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer")
            if renderer.exists { return renderer }
        }
        return .missing
    }

    /// Whether the header comes in the wrapper the account's own playlists have, and who can see it, read leniently
    /// so an odd privacy still leaves it editable.
    static func ownership(in response: JSON) -> (editable: Bool, privacy: PlaylistPrivacy?) {
        for wrapper in headerWrappers(in: response) {
            let editable = wrapper["musicEditablePlaylistDetailHeaderRenderer"]
            guard editable.exists else { continue }
            let privacy = editable["editHeader", "musicPlaylistEditHeaderRenderer", "privacy"].string
            return (true, privacy.flatMap(PlaylistPrivacy.init(rawValue:)))
        }
        return (false, nil)
    }

    /// The two-column page's first tab, then the page's own header.
    private static func headerWrappers(in response: JSON) -> [JSON] {
        let tab = response["contents", "twoColumnBrowseResultsRenderer", "tabs"][0]["tabRenderer", "content", "sectionListRenderer", "contents"][0]
        return [tab, response["header"]]
    }

    /// Whether the album or playlist is in the library, from its save button, which only signed-in requests get:
    /// saved should a press remove the like that saved it.
    static func saved(_ header: JSON) -> Bool? {
        for button in header["buttons"].array {
            let toggle = button["toggleButtonRenderer"]
            let pressed = toggle["isToggled"].bool ?? false
            let off = toggle["defaultServiceEndpoint", "likeEndpoint", "status"].string
            let on = toggle["toggledServiceEndpoint", "likeEndpoint", "status"].string
            // Signed out, the button only asks to sign in.
            guard let off, let on else { continue }
            return (pressed ? on : off) == "INDIFFERENT"
        }
        return nil
    }

    /// Whether a signed-in request was answered signed out, as YouTube answers one whose session has ended.
    static func answeredSignedOut(_ response: JSON) -> Bool {
        response["responseContext", "serviceTrackingParams"].array.contains { service in
            service["params"].array.contains { $0["key"].string == "logged_in" && $0["value"].string == "0" }
        }
    }

    static func trackShelf(in response: JSON) -> JSON {
        sectionList(in: response)["contents"].array.lazy
            .map { $0.first("musicShelfRenderer", "musicPlaylistShelfRenderer") }
            .first { $0.exists } ?? .missing
    }

    /// The whole list's track count from a header's second subtitle: "64
    /// songs • 3 hours", or "1B views • 200 songs • 6+ hours".
    static func trackCount(_ header: JSON) -> Int? {
        let parts = segments(header["secondSubtitle"].runs)
        let index = parts.count > 2 ? 1 : 0
        guard parts.indices.contains(index), let first = parts[index].first?["text"].string else { return nil }
        return Formatting.number(first)
    }

    static func description(_ header: JSON) -> String? {
        let description = header["description"]
        let shelf = description["musicDescriptionShelfRenderer", "description"]
        return (shelf.exists ? shelf : description).text.flatMap { $0.isEmpty ? nil : $0 }
    }
}
