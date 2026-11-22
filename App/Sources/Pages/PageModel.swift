import Observation
import os
import YTMCore

/// Each load is numbered, so a late result of one the screen has moved past
/// never shows.
@Observable
final class PageModel {
    private static let log = Logger(subsystem: "Lily", category: "pages")

    enum Phase {
        case loading
        case loaded(Page)
        case failed(String)
    }

    let route: Route
    private(set) var phase = Phase.loading
    /// Counts the pages shown, so the screen asks for the next step of
    /// `Page.more` once the last has arrived.
    private(set) var step = 0
    /// Counts pages that replaced what was shown on a return, which start from
    /// the top: the reader's place belonged to the page replaced.
    private(set) var replacements = 0

    @ObservationIgnored private var generation = 0
    /// The account the page shown was loaded for.
    @ObservationIgnored private var shownFor: Int?
    /// The page as YouTube sent it, before recent plays join Home's Speed
    /// dial and pins lead Library's playlists, so further steps, the cache,
    /// the saved feed and change checks use YouTube's.
    @ObservationIgnored private var source: Page?

    /// Whether the page stands in for Home's feed until the next visit: the
    /// saved feed or the charts, or a feed cut short by a step that failed.
    @ObservationIgnored private var showsSaved = false
    /// When the cache took the page shown (or it was shown, uncached), so Home
    /// loads afresh once older than pages stay fresh, and a newer copy cached
    /// since shows on the next visit.
    @ObservationIgnored private var shownAt: ContinuousClock.Instant?
    @ObservationIgnored private var loadingMore = false
    /// The entry of the account's own playlist being dragged, which the rows it passes over mark the side of.
    @ObservationIgnored var dragged: String?

    /// Shows a page the cache still holds at once, so a page returned to has
    /// no skeleton or fade; one over five minutes old reloads behind it.
    init(route: Route, app: AppModel) {
        self.route = route
        if app.accountGeneration > 0, let kept = app.keptPage(route) { show(kept.page, for: app) }
    }

    var page: Page? {
        if case .loaded(let page) = phase { page } else { nil }
    }

    /// The layouts of Home's shelves yet to come: neither sent (YouTube's may be dropped) nor shown.
    var shelvesToCome: [CardLayout?] {
        let arrived = Set(((source?.sections ?? []) + (page?.sections ?? [])).map(\.title))
        return YTMusic.homeShelves.filter { !arrived.contains($0.title) }.map(\.layout)
    }

    /// Skips the load if it already holds this account's page, except History
    /// each visit, Home while a stand-in shows, any page once `isStale`, and
    /// one the cache holds a newer copy of.
    func appear(in app: AppModel, returning: Bool) async {
        guard app.accountGeneration > 0 else { return }
        if shownFor == app.accountGeneration {
            rearrange(in: app)
            let newer = app.keptPage(route).map { $0.at != shownAt } ?? false
            if route != .history, !showsSaved, !newer, !isStale(in: app, returning: returning) { return }
        } else {
            clear()
        }
        await load(in: app, cached: true)
    }

    /// Shows a newer copy the cache holds, as one a playlist was put in, without loading: an expired copy's
    /// refresh now would bring back YouTube's list from before the edit.
    func adoptCached(in app: AppModel) {
        guard shownFor == app.accountGeneration, let kept = app.keptPage(route), kept.at != shownAt else { return }
        // A step of the page from before the edit, landing after, would show YouTube's list over it.
        generation += 1
        loadingMore = false
        show(kept.page, for: app)
    }

    /// The old page stays while the new one loads.
    func refresh(in app: AppModel) async {
        app.forget(route)
        await load(in: app, cached: false)
    }

    func retry(in app: AppModel) async {
        clear()
        await load(in: app, cached: false)
    }

    func loadMore(in app: AppModel) async {
        guard let source, source.more != nil, !loadingMore else { return }
        let generation = generation
        let account = app.accountGeneration
        loadingMore = true
        defer { if generation == self.generation { loadingMore = false } }
        guard let step = try? await app.fetchMore(of: source, for: route), isCurrent(generation, account, in: app) else { return }
        // Saved or subscribed to meanwhile, the page shown has it.
        show(step.page.keepingLibraryState(of: self.source), for: app, saved: !step.whole)
    }

    /// Shows an edit made to the page where the reader is, answering what `change` gave; nil, changing nothing,
    /// when it gives nothing or no page shows. `cachedAt` is when the cache took its copy, edited alike, which
    /// is then no newer to adopt on a return.
    func edit<R>(in app: AppModel, cachedAt: ContinuousClock.Instant? = nil, _ change: (inout Page) -> R?) -> R? {
        guard var page = source, let result = change(&page) else { return nil }
        source = page
        phase = .loaded(onScreen(page, in: app))
        if let cachedAt { shownAt = cachedAt }
        return result
    }

    private func load(in app: AppModel, cached: Bool) async {
        generation += 1
        let generation = generation
        let account = app.accountGeneration
        let revision = app.libraryRevisions[route]
        let edits = app.pageEdits[route]
        // No step of the page shown starts meanwhile, as it would land over
        // the page this load brings. Cleared before what this load shows asks
        // for its own next step.
        loadingMore = true
        defer { if generation == self.generation { loadingMore = false } }
        // Only Home's and History's pages start from the top, and only when
        // they differ from what was shown; others keep the reader's place.
        func present(_ page: Page, saved: Bool = false) {
            if cached, let shown = source, route == .home || route == .history,
               shown.sections != page.sections || shown.header != page.header {
                replacements += 1
            }
            show(page, for: app, saved: saved)
        }
        if cached, let kept = app.keptPage(route) {
            if kept.at != shownAt { present(kept.page) }
            guard !kept.isFresh, let fresh = await app.refreshPage(route, since: kept.at) else { return }
            // Home's shelves differ on every load and Home never moves
            // what is shown, so its fresh feed waits for the next visit.
            let onScreen = isCurrent(generation, account, in: app)
            let current = onScreen && (route != .home || !app.isSignedIn)
            let swap = current && (fresh.sections != source?.sections || fresh.header != source?.header)
            // Whether the refresh cached what it brought, not merely that another load replaced the copy.
            let ours = app.pageCache[route]?.page == fresh
            if onScreen || ours {
                let outcome = swap ? "swapped in" : ours ? "cached for the next visit" : "dropped"
                Self.log.debug("refreshed an expired page: \(outcome, privacy: .public)")
            }
            guard current else { return }
            if swap {
                // Where the reader has got to stays.
                show(fresh, for: app)
            } else {
                shownAt = app.pageCache[route]?.at ?? shownAt
            }
            return
        }
        do {
            var page = try await app.fetchPage(route)
            // Edited while it loaded, as by removing a song during a pull to refresh, the page shown is newer.
            guard isCurrent(generation, account, in: app), edits == app.pageEdits[route] || self.page == nil else { return }
            if revision != app.libraryRevisions[route] {
                // Saved or subscribed to while it loaded, as on the page it replaces, and so in the copy cached.
                let kept = page.keepingLibraryState(of: source)
                if app.pageCache[route]?.page == page { app.pageCache[route]?.page = kept }
                page = kept
            }
            present(page)
        } catch {
            // A change of account cancels the last account's requests, whose
            // failure is no news: the page loads afresh for the new one.
            guard isCurrent(generation, account, in: app) else { return }
            // This load dropped any step of the page shown in flight, so the
            // page carries on from where it was.
            guard !Task.isCancelled else {
                if self.page != nil { step += 1 }
                return
            }
            // The saved feed or the charts stand in only once every request
            // has failed, and the next visit asks again; a feed on screen
            // stays instead.
            if route == .home, self.page == nil, let standIn = await app.homeStandIn() {
                guard isCurrent(generation, account, in: app) else { return }
                present(standIn, saved: true)
            } else if self.page == nil {
                phase = .failed(sentence(for: error))
            } else {
                // What was shown stays and carries on from where it was.
                rearrange(in: app)
                app.showToast(sentence(for: error))
                step += 1
            }
        }
    }

    private func isCurrent(_ generation: Int, _ account: Int, in app: AppModel) -> Bool {
        generation == self.generation && account == app.accountGeneration
    }

    /// Home ages out as pages stop being fresh, as the app stays alive for
    /// days; any other page is stale once no longer fresh in the cache, unless
    /// `returning` with it on screen.
    private func isStale(in app: AppModel, returning: Bool) -> Bool {
        guard route == .home else { return !returning && app.keptPage(route)?.isFresh != true }
        guard let shownAt else { return false }
        return shownAt.duration(to: .now) >= AppModel.pageFreshFor
    }

    private func clear() {
        phase = .loading
        source = nil
        shownAt = nil
        showsSaved = false
    }

    /// Mixes what played since into the kept page's Speed dial, and the pins
    /// into Library's playlists. Not a new page, so the reader's place stays.
    func rearrange(in app: AppModel) {
        guard let source, let shown = page else { return }
        let latest = onScreen(source, in: app)
        if latest != shown { phase = .loaded(latest) }
    }

    /// Signed in, Home's Speed dial takes in this phone's recent plays heard
    /// long enough to count, as YouTube's seldom has them.
    private func onScreen(_ page: Page, in app: AppModel) -> Page {
        if route == .home, app.isSignedIn { return page.withRecentPlays(app.history.history.heard) }
        return route.showsPins ? page.withPinnedFirst(app.pinned) : page
    }

    private func show(_ page: Page, for app: AppModel, saved: Bool = false) {
        source = page
        phase = .loaded(onScreen(page, in: app))
        shownFor = app.accountGeneration
        shownAt = app.pageCache[route]?.at ?? .now
        showsSaved = saved
        step += 1
    }
}

extension Route {
    /// Library's pages, where pinned playlists go first.
    var showsPins: Bool { self == .library || self == .libraryPlaylists }
}
