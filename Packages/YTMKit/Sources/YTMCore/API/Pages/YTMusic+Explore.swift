import Foundation

// Explore's pages are the same for every account, so are asked signed out.

extension YTMusic {
    /// Fetched once a session: the same for every account and barely changes.
    private static let moodsAndGenresCache = SessionCache<MoodsAndGenres>()

    @concurrent
    func explorePage() async throws -> Page {
        async let albums = newAlbums()
        async let videos = newVideos()
        let chips = try await moodsAndGenres()
        let sections: [Section?] = [
            .cards("Moods & moments", chips.moods, layout: .chips),
            .cards("Genres", chips.genres, layout: .chips),
            .cards("New albums & singles", await albums, layout: .grid),
            .tracks("New music videos", Array(await videos.prefix(Self.shelfLimit)), mode: .radio),
        ]
        return Page(sections: sections.compactMap(\.self))
    }

    @concurrent
    func genrePage(params: String) async throws -> Page {
        let response = try await innerTube.browse("FEmusic_moods_and_genres_category", params: params, authenticated: false)
        let sections = Renderers.sections(Renderers.sectionList(in: response)).compactMap { section -> Section? in
            guard case .cards(let shelf) = section else { return nil }
            return .cards(shelf.title, shelf.cards.filter { $0.kind == .playlist }, layout: .carousel, more: shelf.more)
        }
        return Page(header: PageHeader(label: "Genre", title: Self.headerTitle(response) ?? ""), sections: sections)
    }

    @concurrent
    func moodsAndGenresPage() async throws -> Page {
        let chips = try await moodsAndGenres()
        let sections: [Section?] = [
            .cards("Moods & moments", chips.moods, layout: .chips),
            .cards("Genres", chips.genres, layout: .chips),
        ]
        return Page(header: PageHeader(title: "Moods & genres"), sections: sections.compactMap(\.self))
    }

    @concurrent
    func newReleasesPage() async throws -> Page {
        try await browsePage("FEmusic_new_releases", params: nil)
    }

    @concurrent
    func chartsPage() async throws -> Page {
        try await browsePage(Charts.browseId, params: Charts.params)
    }

    // MARK: - Shared with Home

    static let shelfLimit = 20

    func moodsAndGenres() async throws -> MoodsAndGenres {
        try await Self.moodsAndGenresCache.value { [innerTube] in
            try MoodsAndGenres(try await innerTube.browse("FEmusic_moods_and_genres", authenticated: false))
        }
    }

    func newAlbums() async -> [Card] {
        await browseSections("FEmusic_new_releases_albums").cards(.album)
    }

    private func newVideos() async -> [Track] {
        await browseSections("FEmusic_new_releases_videos").cards(.song).compactMap(\.track)
    }

    func charts() async throws -> Charts {
        let response = try await innerTube.browse(Charts.browseId, params: Charts.params, authenticated: false)
        return Charts(Renderers.sections(Renderers.sectionList(in: response)))
    }

    private func browseSections(_ id: String, params: String? = nil) async -> [Section] {
        guard let response = try? await innerTube.browse(id, params: params, authenticated: false) else { return [] }
        return Renderers.sections(Renderers.sectionList(in: response))
    }

    private static func headerTitle(_ response: JSON) -> String? {
        response["header", "musicHeaderRenderer", "title"].text
    }
}

/// The last two grids of `FEmusic_moods_and_genres`, moods first.
struct MoodsAndGenres: Sendable {
    var moods: [Card]
    var genres: [Card]

    /// Throws for a reply with no chips, so it isn't kept for the session.
    init(_ response: JSON) throws {
        let grids = Renderers.sectionList(in: response)["contents"].array.suffix(2).map { section in
            section["gridRenderer", "items"].array.compactMap { Renderers.genreCard($0["musicNavigationButtonRenderer"]) }
        }
        // With a single grid, it is the moods.
        moods = grids.first ?? []
        genres = grids.count > 1 ? grids[1] : []
        guard !moods.isEmpty || !genres.isEmpty else {
            throw YTMError(.parse, "YouTube's moods & genres couldn't be read.")
        }
    }

    var all: [Card] { moods + genres }
}

/// Shelves whose "More" opens a playlist are chart lists (top songs, then
/// trending); the rest hold the chart playlists and the top artists.
struct Charts: Sendable {
    static let browseId = "FEmusic_charts"
    static let params = "sgYPRkVtdXNpY19leHBsb3Jl"

    /// The chart lists come without tracks, so trending is read from here.
    var trendingPlaylistId: String?
    /// The trending chart's own tracks, should there be no such playlist.
    var trendingTracks: [Track]
    var artists: [Card]

    init(_ sections: [Section]) {
        let isChartList = { (section: Section) -> Bool in
            if case .playlist? = section.more { true } else { false }
        }
        let others = sections.filter { !isChartList($0) }
        trendingPlaylistId = others.cards(.playlist).first { $0.title.hasPrefix("Trending") }?.id
        trendingTracks = sections.filter(isChartList).dropFirst().first.map(\.tracks) ?? []
        artists = others.cards(.artist)
    }
}

private extension Section {
    var tracks: [Track] {
        if case .tracks(let s) = self { s.tracks } else { [] }
    }
}

private extension [Section] {
    func cards(_ kind: CardKind) -> [Card] {
        flatMap { section -> [Card] in
            guard case .cards(let s) = section else { return [] }
            return s.cards.filter { $0.kind == kind }
        }
    }
}

/// A value kept for the session. Callers arriving mid-fetch share it; a
/// failure isn't kept, so the next caller asks again.
actor SessionCache<Value: Sendable> {
    private var cached: Value?
    private var fetching: Task<Value, any Error>?

    func value(_ fetch: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let cached { return cached }
        if let fetching { return try await fetching.value }
        let task = Task { try await fetch() }
        fetching = task
        defer { fetching = nil }
        let fetched = try await task.value
        cached = fetched
        return fetched
    }
}
