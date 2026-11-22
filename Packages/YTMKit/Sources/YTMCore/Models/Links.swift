/// Addresses on YouTube Music, for copying. Never fetched, so they don't go through the host allowlist.
private func siteLink(_ path: String, _ id: String) -> String {
    "https://music.youtube.com/\(path)\(id)"
}

extension Route {
    /// The page's address on YouTube Music, for those that have one.
    public var link: String? {
        switch self {
        // Albums go by their MPREb_ browse ID.
        case .album(let id): siteLink("browse/", id)
        case .playlist(let id): siteLink("playlist?list=", id)
        case .artist(let id): siteLink("channel/", id)
        default: nil
        }
    }
}

extension Track {
    public var link: String { siteLink("watch?v=", id) }
}

extension Card {
    /// A song card's ID is its video's; a genre has no page of its own on the site.
    public var link: String? {
        kind == .song ? siteLink("watch?v=", id) : route?.link
    }
}
