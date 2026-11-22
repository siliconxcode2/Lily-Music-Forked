import Foundation
import os
import YTMCore

struct CachedPage {
    var page: Page
    var at: ContinuousClock.Instant

    var isFresh: Bool { at.duration(to: .now) < AppModel.pageFreshFor }
}

extension AppModel {
    static let pageCacheSize = 12
    static let pageFreshFor: Duration = .seconds(5 * 60)
    private static let log = Logger(subsystem: "Lily", category: "pages")

    /// The cached copy of `route`, an expired one too, which shows while it reloads. One left half-loaded is none
    /// once expired, as its continuation has expired too.
    func keptPage(_ route: Route) -> CachedPage? {
        guard let kept = pageCache[route], kept.isFresh || kept.page.more == nil else { return nil }
        return kept
    }

    /// History isn't cached, so a song just played shows next time. Leaving the screen doesn't
    /// cancel the request: the page still lands in the cache, and a second visit shares it.
    /// If YouTube fails, a downloaded album or playlist falls back to the songs on the phone, uncached.
    func fetchPage(_ route: Route) async throws -> Page {
        if let load = pageLoads[route] { return try await load.value }
        let generation = accountGeneration
        let edits = pageEdits[route]
        let ahead = route == .home ? homeAhead.take() : nil
        let load = Task<Page, any Error> { [api] in
            defer { if generation == self.accountGeneration { self.pageLoads[route] = nil } }
            let page: Page
            do {
                if let ahead {
                    page = try await withTaskCancellationHandler { try await ahead.value } onCancel: { ahead.cancel() }
                } else {
                    page = try await api.page(route)
                }
            } catch {
                if !Task.isCancelled, let local = self.player.downloads.page(for: route) { return local }
                throw error
            }
            // Edited meanwhile, as Library is by a rename, the copy fetched is older than the edit: the cached one,
            // edited alike, stands instead, and with none it is left uncached.
            if edits != self.pageEdits[route] { return self.pageCache[route]?.page ?? page }
            if generation == self.accountGeneration, route != .history {
                self.cache(page, for: route)
            }
            return page
        }
        pageLoads[route] = load
        return try await load.value
    }

    /// The whole of the expired page cached at `since`, to swap in should it differ; nil should any of it fail, the
    /// copy staying. Shared, and cached even once the screens asking have gone, unless the copy was forgotten or
    /// edited meanwhile; a save or subscription made meanwhile is kept.
    func refreshPage(_ route: Route, since: ContinuousClock.Instant) async -> Page? {
        if let refresh = pageRefreshes[route] { return await refresh.value }
        let generation = accountGeneration
        let edits = pageEdits[route]
        let revision = libraryRevisions[route]
        let refresh = Task<Page?, Never> { [api] in
            defer { if generation == self.accountGeneration { self.pageRefreshes[route] = nil } }
            var fresh: Page
            do {
                var page = try await api.page(route)
                while page.more != nil {
                    let step = try await api.loadStep(page)
                    guard step.whole else { throw YTMError(.network, "Part of the page couldn't be loaded.") }
                    page = step.page
                }
                fresh = page
            } catch {
                // Cancelled, the account changed, which is no failure.
                if !Task.isCancelled { Self.log.warning("could not refresh the page: \(sentence(for: error), privacy: .public)") }
                return nil
            }
            guard generation == self.accountGeneration, let entry = self.pageCache[route], edits == self.pageEdits[route]
            else { return nil }
            if revision != self.libraryRevisions[route] { fresh = fresh.keepingLibraryState(of: entry.page) }
            if entry.at == since { self.cache(fresh, for: route) }
            return fresh
        }
        pageRefreshes[route] = refresh
        return await refresh.value
    }

    /// A page cut short by a failed step is dropped from the cache, so the next visit asks again.
    /// Leaving the screen doesn't cancel it; a step of a page refreshed meanwhile never lands.
    func fetchMore(of page: Page, for route: Route) async throws -> (page: Page, whole: Bool) {
        let generation = accountGeneration
        let since = pageCache[route]?.at
        let step = try await Task { [api] in try await api.loadStep(page) }.value
        if generation == accountGeneration, let kept = pageCache[route], kept.at == since {
            if step.whole { pageCache[route]?.page = step.page.keepingLibraryState(of: kept.page) } else { pageCache[route] = nil }
        }
        return step
    }

    func forget(_ route: Route) {
        pageCache[route] = nil
    }

    /// After the player changed the account's library by rating a song.
    func libraryChanged() {
        for route in [Route.likedSongs, .library, .libraryPlaylists] { forget(route) }
    }

    /// Stands in while YouTube keeps refusing the feed, read off the main actor; nil signed out.
    func homeStandIn() async -> Page? {
        guard isSignedIn else { return nil }
        return await api.homeStandIn()
    }

    /// Last run's Library, as an expired copy, so it shows at once while a fresh one loads. Only where no Library
    /// has loaded meanwhile, and for the account it was saved for.
    func seedLibrary() async {
        let generation = accountGeneration
        guard let saved = await api.savedLibrary(), generation == accountGeneration, pageCache[.library] == nil else { return }
        pageCache[.library] = CachedPage(page: saved, at: .now - Self.pageFreshFor)
    }

    /// Only called for the account signed in now, so Library is saved for it alone.
    private func cache(_ page: Page, for route: Route) {
        // Expired pages are kept to show while they reload, but not those left half-loaded, which load afresh.
        pageCache = pageCache.filter { $0.value.isFresh || $0.value.page.more == nil }
        if pageCache[route] == nil, pageCache.count >= Self.pageCacheSize,
           let oldest = pageCache.min(by: { $0.value.at < $1.value.at })?.key {
            pageCache[oldest] = nil
        }
        pageCache[route] = CachedPage(page: page, at: .now)
        if route == .library { api.saveLibrary(page) }
    }
}
