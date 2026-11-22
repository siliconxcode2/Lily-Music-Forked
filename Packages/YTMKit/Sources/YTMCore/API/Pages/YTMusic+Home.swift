import Foundation

extension YTMusic {
    private static let homeGenres = 12
    private static let trendingLimit = 10

    /// Signed-in Home's shelves in order, each with its layout (nil for songs), so the app can draw them ahead.
    public static let homeShelves: [(title: String, layout: CardLayout?)] = HomeFeed.shelfOrder.map { title in
        switch title {
        case HomeFeed.speedDialTitle: (title, .speedDial)
        case _ where HomeFeed.songShelves.contains(title): (title, nil)
        default: (title, .carousel)
        }
    }

    /// Signed in, the feed's first shelves with `more` fetching the rest;
    /// signed out, the charts.
    @concurrent
    func homePage() async throws -> Page {
        guard await auth.isSignedIn else { return try await publicHome() }
        return try await personalHome()
    }

    /// For a feed YouTube kept refusing: the last saved feed, else the charts.
    /// Never kept as Home, so the next visit asks for the feed again.
    @concurrent
    public func homeStandIn() async -> Page? {
        if let saved = await cachedHome() { return saved }
        return try? await publicHome()
    }

    @concurrent
    func homeShelves(token: String) async throws -> (sections: [Section], next: String?) {
        HomeFeed.nextPage(try await homeFeed(continuation: token))
    }

    /// Arranged as a fresh one is, since one saved by an earlier version may
    /// hold other shelves or another order.
    @concurrent
    private func cachedHome() async -> Page? {
        guard let saved = store.load(Page.self, from: .home) else { return nil }
        let sections = HomeFeed.arranged(saved.sections)
        return sections.isEmpty ? nil : Page(sections: sections)
    }

    /// The saved Home, Library and visitor ID belong to the account they were saved under.
    public func forgetAccount() async {
        store.remove(.home)
        store.remove(.library)
        await innerTube.forgetVisitorData()
    }

    /// Only once whole: a first page alone would stand in later as a shorter,
    /// different feed.
    func saveHome(_ page: Page) {
        store.save(Page(sections: page.sections), to: .home)
    }

    /// Reads on past the first page until a shelf can show, as when Speed
    /// dial comes later.
    private func personalHome() async throws -> Page {
        var (held, next) = try HomeFeed.firstPage(try await homeFeed(continuation: nil))
        var pagesLeft = HomeFeed.continuations
        var sections = HomeFeed.release(&held, after: [], done: next == nil)
        while sections.isEmpty, let token = next, pagesLeft > 0 {
            let page: (sections: [Section], next: String?)
            do {
                page = try await homeShelves(token: token)
            } catch {
                // Left to `loadStep` with the shelves read so far, so the feed
                // keeps its order.
                try Task.checkCancellation()
                guard !held.isEmpty else { throw error }
                return Page(sections: [], more: .shelves(token: token, pagesLeft: pagesLeft, held: held))
            }
            held += page.sections
            next = page.next
            pagesLeft -= 1
            sections = HomeFeed.release(&held, after: [], done: next == nil || pagesLeft == 0)
        }
        guard !sections.isEmpty else { throw YTMError(.parse, "YouTube sent an empty Home feed.") }
        if let next, pagesLeft > 0, !HomeFeed.isComplete(sections) {
            return Page(sections: sections, more: .shelves(token: next, pagesLeft: pagesLeft, held: held))
        }
        let page = Page(sections: sections)
        saveHome(page)
        return page
    }

    /// Asked again while YouTube refuses it, up to `HomeFeed.attempts` times.
    private func homeFeed(continuation token: String?) async throws -> JSON {
        var attempt = 1
        while true {
            do {
                if let token { return try await innerTube.continuation(token) }
                return try await innerTube.browse("FEmusic_home")
            } catch where HomeFeed.isRefusal(error) && attempt < HomeFeed.attempts {
                try await Task.sleep(for: HomeFeed.retryDelay(after: attempt))
                attempt += 1
            }
        }
    }

    /// Only the charts must arrive.
    private func publicHome() async throws -> Page {
        async let albums = newAlbums()
        async let genres = genreChips()
        let charts = try await charts()
        let trending = await trendingTracks(charts)
        let sections: [Section?] = [
            .tracks("Trending", Array(trending.prefix(Self.trendingLimit)), mode: .section),
            .cards("New releases", Array(await albums.prefix(Self.shelfLimit)), layout: .carousel),
            .cards("Top artists", Array(charts.artists.prefix(Self.shelfLimit)), layout: .carousel),
            await genres,
        ]
        return Page(sections: sections.compactMap(\.self))
    }

    /// From the trending playlist, as the chart lists come empty; none should
    /// it fail.
    private func trendingTracks(_ charts: Charts) async -> [Track] {
        guard let id = charts.trendingPlaylistId else { return charts.trendingTracks }
        return (try? await playlistTracks(id, limit: Self.trendingLimit, asOwner: false)) ?? []
    }

    private func genreChips() async -> Section? {
        guard let chips = try? await moodsAndGenres() else { return nil }
        return .cards("Browse moods & genres", Array(chips.all.prefix(Self.homeGenres)), layout: .chips)
    }
}
