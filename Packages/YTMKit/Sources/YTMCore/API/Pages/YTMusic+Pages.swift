import Foundation

extension YTMusic {
    @concurrent
    public func page(_ route: Route) async throws -> Page {
        switch route {
        case .home: try await homePage()
        case .explore: try await explorePage()
        case .library: try await libraryPage()
        case .history: try await historyPage()
        case .search(let query): try await searchPage(query)
        case .album(let id): try await albumPage(id)
        case .playlist(let id): try await playlistPage(id)
        case .artist(let id): try await artistPage(id)
        case .genre(let params): try await genrePage(params: params)
        case .libraryPlaylists, .libraryAlbums, .libraryArtists, .librarySongs: try await libraryListPage(route)
        case .browse(let id, let params): try await browsePage(id, params: params)
        case .newReleases: try await newReleasesPage()
        case .charts: try await chartsPage()
        case .moodsAndGenres: try await moodsAndGenresPage()
        case .downloads: throw YTMError(.notFound, "Downloads are kept on the phone, not on YouTube.")
        }
    }

    /// Leaves `more` set while there is another step. A step that fails ends
    /// the page with what arrived; only cancellation throws, so a page left
    /// mid-load is never taken as whole.
    @concurrent
    public func loadMore(_ page: Page) async throws -> Page {
        try await loadStep(page).page
    }

    /// As `loadMore`; not `whole` once a step failed, so the app keeps the
    /// page neither as Home nor as the whole playlist.
    @concurrent
    public func loadStep(_ page: Page) async throws -> (page: Page, whole: Bool) {
        var page = page
        var whole = true
        switch page.more {
        case nil:
            break
        case .tracks(let token, var seen, let fetched)?:
            page.more = nil
            guard case .tracks? = page.sections.first else { return (page, whole) }
            let entries = page.header?.editable == true
            guard let batch = try await playlistBatch(after: token, asOwner: true, entries: entries, seen: &seen) else {
                return (page, false)
            }
            page = Renderers.addingBatch(batch, to: page, seen: seen, fetched: fetched)
        case .shelves(let token, let pagesLeft, var held)?:
            page.more = nil
            var next: String?
            do {
                let shelves = try await homeShelves(token: token)
                held += shelves.sections
                next = shelves.next
            } catch {
                try Task.checkCancellation()
                whole = false
            }
            let done = next == nil || pagesLeft <= 1
            page.sections += HomeFeed.release(&held, after: page.sections, done: done)
            if let next, !done, !HomeFeed.isComplete(page.sections) {
                page.more = .shelves(token: next, pagesLeft: pagesLeft - 1, held: held)
            } else if whole, await auth.isSignedIn {
                saveHome(page)
            }
        }
        return (page, whole)
    }
}
