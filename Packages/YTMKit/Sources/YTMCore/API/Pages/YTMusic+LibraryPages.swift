import Foundation

extension YTMusic {
    private static let librarySongsShown = 10
    private static let librarySignIn = "Sign in to see your playlists, albums and artists."

    @concurrent
    func libraryPage() async throws -> Page {
        try await requireSignIn(Self.librarySignIn)
        async let albums = try? libraryShelf(.albums)
        async let artists = try? libraryShelf(.artists)
        async let songs = try? libraryShelf(.songs)
        let playlists = try await libraryPlaylists(all: false)
        let (albumShelf, artistShelf, songShelf) = await (albums ?? .missing, artists ?? .missing, songs ?? .missing)
        let liked = Renderers.tracks(LibraryList.items(songShelf))
        let moreSongs = liked.count > Self.librarySongsShown || Renderers.continuation(songShelf) != nil
        let sections: [Section?] = [
            .cards("Playlists", playlists.cards, layout: .grid, more: playlists.hasMore ? .libraryPlaylists : nil),
            Self.librarySection(.albums, albumShelf),
            Self.librarySection(.artists, artistShelf),
            .tracks("Songs", Array(liked.prefix(Self.librarySongsShown)), mode: .section, more: moreSongs ? .librarySongs : nil),
        ]
        return Page(sections: sections.compactMap(\.self))
    }

    /// The list in full, but for the liked songs, whose rest `more` fetches.
    @concurrent
    func libraryListPage(_ route: Route) async throws -> Page {
        guard let list = LibraryList(route) else { throw YTMError(.notFound, "This page doesn't exist.") }
        try await requireSignIn(Self.librarySignIn)
        let header = PageHeader(label: "Library", title: list.title)
        let cards: [Card]
        switch list {
        case .songs:
            let shelf = try await libraryShelf(list)
            var seen = Set<String>()
            let (tracks, fetched) = Renderers.playlistRows(LibraryList.items(shelf), seen: &seen)
            guard let section = Section.tracks("", tracks, mode: .section) else { return Page(header: header, sections: []) }
            let more = Renderers.continuation(shelf).map { Continuation.tracks(token: $0, seen: seen, fetched: fetched) }
            return Page(header: header, sections: [section], more: more)
        case .playlists:
            cards = try await libraryPlaylists(all: true).cards
        case .albums, .artists:
            cards = try await libraryCards(try await libraryShelf(list), all: true)
        }
        return Page(header: header, sections: [Section.cards("", cards, layout: .grid)].compactMap(\.self))
    }

    /// Library as it last loaded, shown at once on the next start; the caller keeps it to the account it is for.
    public func saveLibrary(_ page: Page) {
        store.save(page, to: .library)
    }

    @concurrent
    public func savedLibrary() async -> Page? {
        store.load(Page.self, from: .library)
    }

    func requireSignIn(_ message: String) async throws {
        guard await auth.isSignedIn else { throw YTMError(.notSignedIn, message) }
    }

    private static func librarySection(_ list: LibraryList, _ shelf: JSON) -> Section? {
        let more = Renderers.continuation(shelf) == nil ? nil : list.route
        return .cards(list.title, Renderers.cards(LibraryList.items(shelf)), layout: .grid, more: more)
    }

    /// Liked music, then the saved playlists.
    private func libraryPlaylists(all: Bool) async throws -> (cards: [Card], hasMore: Bool) {
        async let liked = likedMusic()
        let shelf = try await libraryShelf(.playlists)
        let saved = try await libraryCards(shelf, all: all)
        let likedCard = await liked
        // Episodes for Later is a podcast page, which does not open as a
        // playlist; Liked music leads the list already.
        let playlists = saved.filter {
            $0.id != BuiltInPlaylist.episodesForLater && (likedCard == nil || $0.id != BuiltInPlaylist.likedMusic)
        }
        return ((likedCard.map { [$0] } ?? []) + playlists, !all && Renderers.continuation(shelf) != nil)
    }

    private func likedMusic() async -> Card? {
        guard let response = try? await innerTube.browse("VL" + BuiltInPlaylist.likedMusic) else { return nil }
        return LibraryList.likedMusicCard(response)
    }

    private func libraryShelf(_ list: LibraryList) async throws -> JSON {
        LibraryList.shelf(in: try await innerTube.continuation(list.token))
    }

    private func libraryCards(_ shelf: JSON, all: Bool) async throws -> [Card] {
        var cards = Renderers.cards(LibraryList.items(shelf))
        if all { try await following(shelf, authenticated: true) { cards += Renderers.cards($0) } }
        return cards
    }
}

extension Page {
    /// Library's playlists with the `pinned` ones first, in the order pinned, then the rest in theirs; a pinned ID
    /// not among them is passed over. Applied as the page shows, so the cache keeps YouTube's order.
    public func withPinnedFirst(_ pinned: [String]) -> Page {
        guard !pinned.isEmpty, let index = sections.firstIndex(where: { if case .cards = $0 { true } else { false } }),
              case .cards(var section) = sections[index] else { return self }
        let lead = pinned.flatMap { id in section.cards.filter { $0.id == id } }
        let pins = Set(pinned)
        section.cards = lead + section.cards.filter { !pins.contains($0.id) }
        var page = self
        page.sections[index] = .cards(section)
        return page
    }
}

enum LibraryList: CaseIterable {
    case playlists, albums, artists, songs

    init?(_ route: Route) {
        guard let list = Self.allCases.first(where: { $0.route == route }) else { return nil }
        self = list
    }

    var route: Route {
        switch self {
        case .playlists: .libraryPlaylists
        case .albums: .libraryAlbums
        case .artists: .libraryArtists
        case .songs: .librarySongs
        }
    }

    var title: String {
        switch self {
        case .playlists: "Playlists"
        case .albums: "Albums"
        case .artists: "Artists"
        case .songs: "Songs"
        }
    }

    /// Opens the list sorted as YouTube Music's library sorts it.
    var token: String {
        switch self {
        case .playlists: "4qmFsgIrEhdGRW11c2ljX2xpa2VkX3BsYXlsaXN0cxoQZ2dNR0tnUUlBQkFCb0FZQg%3D%3D"
        case .albums: "4qmFsgIoEhRGRW11c2ljX2xpa2VkX2FsYnVtcxoQZ2dNR0tnUUlBQkFCb0FZQg%3D%3D"
        case .artists: "4qmFsgIyEh5GRW11c2ljX2xpYnJhcnlfY29ycHVzX2FydGlzdHMaEGdnTUdLZ1FJQUJBQm9BWUI%3D"
        case .songs: "4qmFsgIoEhRGRW11c2ljX2xpa2VkX3ZpZGVvcxoQZ2dNR0tnUUlBQkFCb0FZQg%3D%3D"
        }
    }

    /// The first batch comes in a section list, or as the grid or shelf's own
    /// continuation.
    static func shelf(in response: JSON) -> JSON {
        let list = Renderers.sectionList(in: response)
        guard list.exists else { return response["continuationContents"].onlyValue?.value ?? .missing }
        return list["contents"].array.lazy.compactMap(\.onlyValue)
            .first { $0.key == "gridRenderer" || $0.key == "musicShelfRenderer" }?.value ?? .missing
    }

    static func items(_ shelf: JSON) -> [JSON] {
        shelf.first("items", "contents").array
    }

    /// Counts the songs listed when they all are, else the header's count.
    /// Nil when the page has no list of songs.
    static func likedMusicCard(_ response: JSON) -> Card? {
        let shelf = Renderers.trackShelf(in: response)
        guard shelf.exists else { return nil }
        let header = Renderers.detailHeader(in: response)
        let count = Renderers.continuation(shelf) == nil ? Renderers.tracks(shelf["contents"].array).count : Renderers.trackCount(header)
        return Card(
            kind: .playlist, id: BuiltInPlaylist.likedMusic, title: "Liked music",
            subtitle: count.map { "Auto playlist • \(Formatting.songs($0))" } ?? "Auto playlist",
            thumbnail: Thumbnail.pick(Thumbnail.list(in: header), edge: Thumbnail.card)
        )
    }
}
