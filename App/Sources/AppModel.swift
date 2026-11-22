import Observation
import SwiftUI
import YTMAudio
import YTMCore
import YTMPlayback

enum AppSheet: Identifiable, Hashable {
    case nowPlaying
    case settings
    case signIn
    case addToPlaylist(Track)

    var id: Self { self }
}

enum AppTab: Hashable, CaseIterable {
    case home, explore, library, history, search
}

@Observable
final class TabNavigation {
    var routes: [Route] = []
}

struct Toast: Equatable {
    let id: Int
    let message: String
}

/// Everything here runs on the main actor; the services do their work off it.
@Observable
final class AppModel {
    static let toastFor: Duration = .seconds(5)
    /// After the launch's first page has had the network.
    static let renewSignInAfter: Duration = .seconds(10)
    /// Less often than an open YouTube tab, as a cookie found stale is renewed when YouTube answers signed out.
    static let renewSignInEvery: Duration = .seconds(60 * 60)
    /// The least time between cookie checks, after one that didn't find the cookie rejected.
    static let signInRecheckAfter: Duration = .seconds(10 * 60)
    /// How long music plays on in the background before the artwork cache shrinks, as Windows waits once minimised.
    static let trimArtworkAfter: Duration = .seconds(60)

    let api: YTMusic
    let player: PlayerController
    let audio: AudioPlayer
    let settings: SettingsStore
    let history: LocalHistory

    var tab: AppTab = .home
    var sheet: AppSheet? {
        // Closing Now Playing under its picker doesn't write the picker's
        // binding back, so it would reopen with the next Now Playing.
        didSet { if sheet != .nowPlaying, nowPlayingPicker != nil { nowPlayingPicker = nil } }
    }
    /// Now Playing is on screen or still zooming away, while pages fill past their edges (`PastEdges`).
    var nowPlayingShown = false
    /// iPhone Duo, which Settings offers fold to scrub on.
    var hasHinge = false
    /// The playlist picker opened from Now Playing, shown over it so its open panel stays.
    var nowPlayingPicker: Track?
    /// The keyboard is up, so the mini player steps aside rather than ride above it.
    var isSearching = false

    /// A stored sign-in cookie counts, so pages load without waiting for YouTube to confirm it.
    private(set) var isSignedIn = false
    private(set) var account: Account?
    /// Bumped whenever the account changes, so results asked for by the last account are
    /// dropped. Zero until the stored sign-in has been read, before which pages don't load, bar
    /// Home's launch request, which the first load of Home takes over under the generation it is in.
    private(set) var accountGeneration = 0

    private(set) var theme: Theme
    /// Playlist IDs pinned to the top of Library's playlists, kept apart from the settings so only the views
    /// showing pins redraw as they change.
    private(set) var pinned: [String] = []
    /// Counts the playlists put in Library's cached pages, so a Library page on screen, as under Now Playing,
    /// shows one at once.
    var playlistsAdded = 0
    private(set) var artwork: ArtworkColours?
    private(set) var toast: Toast?

    @ObservationIgnored private let home = TabNavigation()
    @ObservationIgnored private let explore = TabNavigation()
    @ObservationIgnored private let library = TabNavigation()
    @ObservationIgnored private let played = TabNavigation()
    @ObservationIgnored private let search = TabNavigation()
    @ObservationIgnored var pageCache: [Route: CachedPage] = [:]
    /// Shared by every screen asking for the same route.
    @ObservationIgnored var pageLoads: [Route: Task<Page, any Error>] = [:]
    /// Expired pages being fetched whole, shared by every screen showing the copy.
    @ObservationIgnored var pageRefreshes: [Route: Task<Page?, Never>] = [:]
    /// Bumped by each edit to a page, by its route, so a load asked for before one never puts back what it changed.
    @ObservationIgnored var pageEdits: [Route: Int] = [:]
    /// Bumped by each save or subscribe shown, by the route of its page, so a copy fetched before one keeps what it set.
    @ObservationIgnored var libraryRevisions: [Route: Int] = [:]
    /// What a save or subscribe still being answered changes, so a second press is ignored.
    @ObservationIgnored var libraryEdits: Set<String> = []
    /// The launch's Home request, which the first load of Home takes over.
    @ObservationIgnored var homeAhead: Task<Page, any Error>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// The wait for Last.fm access, which outlives Settings.
    private var lastFMWait: Task<Void, Never>?
    @ObservationIgnored private var downloadTime = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var artworkTrim: Task<Void, Never>?

    init(api: YTMusic = .shared, settings: SettingsStore = .shared, history: LocalHistory = .shared) {
        self.api = api
        self.settings = settings
        self.history = history
        audio = AudioPlayer { Proxy.configurations }
        player = PlayerController(api: api, settings: settings, history: history, audio: audio)
        theme = Theme(settings: settings.value, artworkAccent: nil)
        // Detached, as the main actor builds the first frame before any task of its own runs.
        homeAhead = Task.detached(priority: .userInitiated) { [api] in try await api.page(.home) }
        // Read here, for the app's life: a view's task would be cancelled by a scene teardown,
        // ending the one-consumer stream.
        Task { [weak self, toasts = player.toasts] in
            for await message in toasts { self?.showToast(message) }
        }
    }

    /// Signed in, Home's feed is asked for at once and the launch's other requests wait for it
    /// (two seconds at most), so they don't slow it.
    func start() async {
        isSignedIn = await api.auth.isSignedIn
        // Before the load, which belongs to the generation it starts in.
        accountGeneration += 1
        // Read from here, once the sign-in is known; an answer that came before waits in the stream.
        Task { [weak self, lost = api.auth.signInLost] in
            for await _ in lost { await self?.checkSignIn() }
        }
        Task { [api] in
            try? await Task.sleep(for: Self.renewSignInAfter)
            while !Task.isCancelled {
                await api.renewSignIn()
                try? await Task.sleep(for: Self.renewSignInEvery)
            }
        }
        let home = isSignedIn ? Task { try await fetchPage(.home) } : nil
        if isSignedIn { Task { await showLastRun() } }
        Task { await ImagePipeline.preconnect() }
        let homeSettled = Task { await Self.settled(home, within: .seconds(2)) }
        await player.start { await homeSettled.value }
        await homeSettled.value
        await refreshAccount()
    }

    /// The account's name and picture, and Library, as the last run saw them, while fresh ones load.
    private func showLastRun() async {
        let generation = accountGeneration
        await settings.load()
        if generation == accountGeneration, account == nil { account = settings.value.account }
        await seedLibrary()
    }

    /// Not a task group, which would wait out `load` all the same.
    private nonisolated static func settled(_ load: Task<Page, any Error>?, within limit: Duration) async {
        guard let load else { return }
        let (done, finish) = AsyncStream.makeStream(of: Void.self)
        Task { _ = try? await load.value; finish.finish() }
        Task { try? await Task.sleep(for: limit); finish.finish() }
        for await _ in done {}
    }

    /// Replaces `pinned` only when it changes, so views reading it redraw only then.
    func followPinned() async {
        for await pinned in Observations({ [settings] in settings.value.pinned }) where pinned != self.pinned {
            self.pinned = pinned
        }
    }

    /// Pins a playlist after those pinned already, or unpins it.
    func togglePin(_ card: Card) {
        var pinned = settings.value.pinned
        if pinned.contains(card.id) { pinned.removeAll { $0 == card.id } } else { pinned.append(card.id) }
        settings.value.pinned = pinned
    }

    /// Replaces `theme` only when it changes, so views reading it redraw only then.
    func followTheme() async {
        let changes = Observations { [settings] in
            Theme(settings: settings.value, artworkAccent: self.artwork?.vivid)
        }
        for await theme in changes where theme != self.theme {
            self.theme = theme
        }
    }

    /// The colours are sampled from the small copy, else any other in memory, as the palette reads
    /// only 16 pixels square, so they never wait for or draw down the large one.
    func followArtwork(of url: String?) async {
        // Without artwork, the last song's colour would linger.
        guard let url else {
            artwork = nil
            return
        }
        let colours: ArtworkColours?
        // At 3x, the scale the shared pixel sizes are set for, so the card a song started from is found.
        if let image = ArtworkImage.cachedAnySize(url, preferring: ImagePipeline.smallEdge, scale: 3) {
            colours = await ArtworkColours.of(image)
        } else {
            colours = await ArtworkColours.of(url: url, pixelEdge: ImagePipeline.smallEdge)
        }
        guard let colours, !Task.isCancelled else { return }
        artwork = colours
    }

    /// A signed-out menu leaves the sign-in to `checkSignIn`, which its answer sets off.
    func refreshAccount() async {
        guard isSignedIn else {
            account = nil
            return
        }
        let generation = accountGeneration
        let found: Account?
        do {
            found = try await api.account()
        } catch {
            // YouTube couldn't be asked, which says nothing of the sign-in.
            return
        }
        guard generation == accountGeneration else { return }
        account = found
        // Kept for the next start, written only as it changes.
        if let found, settings.value.account != found { settings.value.account = found }
    }

    /// Once YouTube answers a signed-in request as signed out: checks the cookie, as the session
    /// can end at any time, and drops a dead one.
    private func checkSignIn() async {
        // An answer to a request sent before the cookie was removed.
        guard isSignedIn else { return }
        let generation = accountGeneration
        var valid = await api.isSessionValid()
        // A stale cookie may only need renewing.
        if valid == false {
            await api.renewSignIn()
            valid = await api.isSessionValid()
        }
        // Signing in or out meanwhile makes the answer another account's.
        guard generation == accountGeneration else { return }
        if valid == false {
            await signOut(quietly: true)
            showToast("YouTube signed you out")
            return
        }
        // A renewed session has its name and picture back.
        if account == nil { await refreshAccount() }
        // Answers arriving meanwhile wait, so the cookie isn't checked at each.
        try? await Task.sleep(for: Self.signInRecheckAfter)
    }

    /// Drops everything the last account loaded. `quietly`, as for a sign-in YouTube rejected,
    /// skips announcing it and switching to Library or Home.
    func accountChanged(quietly: Bool = false) async {
        await api.forgetAccount()
        isSignedIn = await api.auth.isSignedIn
        account = nil
        // It may be another account's.
        settings.value.account = nil
        // Together with the bump, so no page asked for by the last account
        // lands in the cache once it is cleared.
        pageCache.removeAll()
        // A request the last account made must not be shared with the next.
        pageLoads.values.forEach { $0.cancel() }
        pageLoads.removeAll()
        pageRefreshes.values.forEach { $0.cancel() }
        pageRefreshes.removeAll()
        homeAhead.take()?.cancel()
        accountGeneration += 1
        if !quietly {
            sheet = nil
            showToast(isSignedIn ? "Signed in" : "Signed out")
            tab = isSignedIn ? .library : .home
            navigation(for: tab).routes.removeAll()
        }
        await player.accountDidChange()
        await refreshAccount()
    }

    func signOut(quietly: Bool = false) async {
        await api.auth.signOut()
        await accountChanged(quietly: quietly)
    }

    var isConnectingLastFM: Bool { lastFMWait != nil }

    /// Waits, whatever Settings does, until access is allowed, refused or cancelled.
    func connectLastFM(open: OpenURLAction) {
        lastFMWait = Task { [weak self] in
            let message: String?
            do {
                try await LastFM.shared.signIn { url in await open(url) }
                message = await LastFM.shared.username.map { "Scrobbling to Last.fm as \($0)" }
            } catch {
                // Cancelled, the user stopped waiting, which needs no word.
                message = Task.isCancelled ? nil : sentence(for: error)
            }
            guard let self, !Task.isCancelled else { return }
            lastFMWait = nil
            if let message { showToast(message) }
        }
    }

    func cancelLastFMConnect() {
        lastFMWait?.cancel()
        lastFMWait = nil
    }

    func showToast(_ message: String) {
        toast = Toast(id: (toast?.id ?? 0) + 1, message: message)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: Self.toastFor)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// iOS gives downloads only a short while in the background; while music plays they carry on anyway.
    func keepDownloading(_ active: Bool) {
        if active, downloadTime == .invalid {
            downloadTime = UIApplication.shared.beginBackgroundTask(withName: "Downloads") { [weak self] in
                self?.player.persistSession()
                self?.keepDownloading(false)
            }
        } else if !active, downloadTime != .invalid {
            UIApplication.shared.endBackgroundTask(downloadTime)
            downloadTime = .invalid
        }
    }

    /// Shrinks the artwork cache in the background, keeping the playing song's: after `trimArtworkAfter` while music
    /// plays on, so a quick look elsewhere doesn't cost Back its art, and at once otherwise, as a suspended app runs
    /// no timer to do it later.
    func hideArtwork(_ hidden: Bool) {
        artworkTrim?.cancel()
        artworkTrim = nil
        if !hidden {
            ImagePipeline.shared.setHidden(false)
        } else if !player.isPlaying {
            ImagePipeline.shared.setHidden(true, keeping: player.current?.thumbnail)
        } else {
            artworkTrim = Task { [weak self] in
                try? await Task.sleep(for: Self.trimArtworkAfter)
                guard let self, !Task.isCancelled else { return }
                ImagePipeline.shared.setHidden(true, keeping: player.current?.thumbnail)
            }
        }
    }

    /// Each tab's own stack of pages, observed apart so a push redraws one.
    func navigation(for tab: AppTab) -> TabNavigation {
        switch tab {
        case .home: home
        case .explore: explore
        case .library: library
        case .history: played
        case .search: search
        }
    }

    /// Pushes `route` on the tab in view, closing whatever is presented.
    func open(_ route: Route) {
        sheet = nil
        let stack = navigation(for: tab)
        // Already on top: pushing again would only stack a copy.
        guard stack.routes.last != route else { return }
        stack.routes.append(route)
    }
}
