import Foundation

extension YTMusic {
    /// Each kind from its own filtered search, all at once. Only the songs
    /// must arrive; any other kind that fails is left out.
    func searchPage(_ query: String) async throws -> Page {
        async let top = try? topResult(query)
        async let songs = search(query, .songs)
        // Uploads too: slowed and sped-up edits, mashups and live versions
        // are videos, not songs, on YouTube Music.
        async let videos = try? search(query, .videos)
        async let artists = try? search(query, .artists)
        async let albums = try? search(query, .albums)
        async let playlists = try? search(query, .playlists)
        let sections = try await [top, songs, videos, artists, albums, playlists].compactMap(\.self)
        guard !sections.isEmpty else { throw YTMError(.notFound, "No results for \u{201C}\(query)\u{201D}") }
        return Page(sections: sections)
    }

    func search(_ query: String, _ kind: SearchKind) async throws -> Section? {
        let response = try await innerTube.post("search", body: ["query": query, "params": kind.params], authenticated: false)
        return Renderers.sections(Renderers.sectionList(in: response), mode: .radio, layout: .carousel).first?
            .retitled(kind.title)
    }

    /// Only when YouTube Music leads with an artist, album or playlist; a
    /// song or video in the lead shows among the others.
    private func topResult(_ query: String) async throws -> Section? {
        let response = try await innerTube.post("search", body: ["query": query], authenticated: false)
        guard let lead = Renderers.section(Renderers.sectionList(in: response)["contents"][0]),
              case .cards(let cards) = lead, cards.layout == .top
        else { return nil }
        return lead
    }
}

enum SearchKind {
    case songs, videos, artists, albums, playlists

    var params: String {
        switch self {
        case .songs: "EgWKAQIIAWoQEAMQBBAJEAoQBRAREBAQFQ%3D%3D"
        case .videos: "EgWKAQIQAWoQEAMQBBAJEAoQBRAREBAQFQ%3D%3D"
        case .albums: "EgWKAQIYAWoQEAMQBBAJEAoQBRAREBAQFQ%3D%3D"
        case .artists: "EgWKAQIgAWoQEAMQBBAJEAoQBRAREBAQFQ%3D%3D"
        // YouTube Music's own playlists.
        case .playlists: "EgeKAQQoADgBahIQAxAEEAkQDhAKEAUQERAQEBU%3D"
        }
    }

    var title: String {
        switch self {
        case .songs: "Songs"
        case .videos: "Videos"
        case .artists: "Artists"
        case .albums: "Albums"
        case .playlists: "Playlists"
        }
    }
}

extension Section {
    /// Drops the "Show all" a search shelf links to.
    func retitled(_ title: String) -> Section {
        switch self {
        case .tracks(var section):
            section.title = title
            section.more = nil
            return .tracks(section)
        case .cards(var section):
            section.title = title
            section.more = nil
            return .cards(section)
        }
    }
}
