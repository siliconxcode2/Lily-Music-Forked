import Foundation
import YTMCore

/// Albums, playlists and smart downloads, and the pages that show what is downloaded.
extension Downloads {
    /// Collections and smart picks are brought up to date once a day, as YouTube Music's are.
    static let refreshEvery: TimeInterval = 24 * 60 * 60
    /// Smart downloads mix the latest plays with radios of this many of them.
    static let smartSeeds = 3

    public static func isDownloadable(_ route: Route) -> Bool {
        switch route {
        case .album, .playlist: true
        default: false
        }
    }

    /// Failed songs count as done, so an album with a song YouTube won't send still finishes.
    public func state(of route: Route) -> DownloadState {
        if fetching.contains(route) { return .waiting }
        guard let collection = index.collections.first(where: { $0.route == route }) else { return .none }
        let tracks = collection.tracks
        let done = tracks.count { index.songs[$0.id] != nil || failed.contains($0.id) }
        guard done < tracks.count else { return .downloaded }
        guard canDownload else { return .waiting }
        let partial = tracks.reduce(0) { $0 + (progress[$1.id] ?? 0) }
        return .downloading((Double(done) + partial) / Double(tracks.count))
    }

    /// A playlist page shows its songs a batch at a time, so the rest are asked for.
    public func download(_ page: Page, from route: Route) async {
        guard let header = page.header, Self.isDownloadable(route), state(of: route) == .none else { return }
        let tracks = page.more == nil ? page.headerTracks : await fetchTracks(of: route)
        add(route, title: header.title, subtitle: header.subtitle, thumbnail: header.thumbnail, tracks: tracks)
    }

    public func download(_ card: Card) async {
        guard let route = card.route, Self.isDownloadable(route), state(of: route) == .none else { return }
        add(route, title: card.title, subtitle: card.subtitle, thumbnail: card.thumbnail, tracks: await fetchTracks(of: route))
    }

    public func remove(_ route: Route) {
        fetching.remove(route)
        index.collections.removeAll { $0.route == route }
        changed()
    }

    /// Keeps a downloaded Liked music in step with likes straight away, rather than at the daily sync.
    func rated(_ track: Track, _ rating: Rating) {
        guard let at = index.collections.firstIndex(where: { $0.route == .likedSongs }) else { return }
        index.collections[at].tracks.removeAll { $0.id == track.id }
        if rating == .like { index.collections[at].tracks.insert(track, at: 0) }
        changed()
    }

    /// Nil when nothing is downloaded or on its way.
    public var page: Page? {
        guard !isEmpty else { return nil }
        let songs = index.songs.values.sorted { $0.added > $1.added }.map(\.track)
        let coming = wanted.filter { index.songs[$0.id] == nil && !failed.contains($0.id) }
        // Downloaded songs first, so the header's Play and Shuffle play only what is on the phone.
        let sections = [
            Section.tracks("Songs", songs, mode: .section),
            Section.tracks(status(coming.count), coming, mode: .section),
            Section.cards("Albums and playlists", index.collections.compactMap(\.card), layout: .grid),
        ].compactMap(\.self)
        let meta = "\(Formatting.songs(songs.count)) • \(bytes.formatted(.byteCount(style: .file)))"
        return Page(header: PageHeader(title: "Downloads", meta: meta), sections: sections)
    }

    /// A downloaded album or playlist as the phone holds it, for when YouTube can't be reached.
    public func page(for route: Route) -> Page? {
        guard let collection = index.collections.first(where: { $0.route == route }) else { return nil }
        let tracks = collection.tracks.filter { index.songs[$0.id] != nil }
        guard !tracks.isEmpty else { return nil }
        let album = if case .album = route { true } else { false }
        let header = PageHeader(
            label: album ? "Album" : "Playlist", title: collection.title, subtitle: collection.subtitle,
            meta: Formatting.songs(tracks.count), thumbnail: collection.thumbnail
        )
        return Page(header: header, sections: [.tracks(TrackSection(title: "", tracks: tracks, mode: .section, numbered: album))])
    }

    /// Syncs albums and playlists with YouTube and picks smart downloads afresh, each when due.
    func refreshIfDue() {
        guard canDownload, !held, refreshing == nil else { return }
        let syncing = !index.collections.isEmpty && Self.isDue(index.collectionsSynced)
        let picking = settings.value.smartDownloads && Self.isDue(index.smartRefreshed)
        guard syncing || picking else { return }
        refreshing = Task { [weak self] in
            let again = await self?.refresh(syncing: syncing) ?? false
            guard let self, !Task.isCancelled else { return }
            refreshing = nil
            if again { refreshIfDue() }
        }
    }

    /// Only a full, non-empty answer replaces a list, so a bad connection never loses a download.
    /// Returns true if the smart settings changed meanwhile, so the picks are due again.
    private func refresh(syncing: Bool) async -> Bool {
        if syncing {
            var synced = true
            for route in index.collections.map(\.route) {
                let tracks = try? await tracks(of: route)
                guard !Task.isCancelled else { return false }
                guard let tracks, !tracks.isEmpty, let at = index.collections.firstIndex(where: { $0.route == route }) else {
                    synced = false
                    continue
                }
                index.collections[at].tracks = tracks
            }
            if synced { index.collectionsSynced = .now }
            keepCollectionArtwork()
        }
        var again = false
        // Read afresh, as the setting may have changed while collections synced.
        if settings.value.smartDownloads, Self.isDue(index.smartRefreshed) {
            let (enabled, count) = (settings.value.smartDownloads, settings.value.smartDownloadCount)
            let picks = await smartPicks(count)
            guard !Task.isCancelled else { return false }
            if settings.value.smartDownloads != enabled || settings.value.smartDownloadCount != count {
                again = true
            } else if let picks {
                index.smart = picks
                index.smartRefreshed = .now
            }
        }
        failed.removeAll()
        changed()
        return again
    }

    /// Recent plays mixed with radios of the latest few, as YouTube Music's are. Nil, keeping the
    /// last picks, if nothing has played yet or a radio fails.
    private func smartPicks(_ count: Int) async -> [Track]? {
        let played = history.history.tracks
        guard !played.isEmpty else { return nil }
        let music = music
        let radios = await withTaskGroup(of: [Track]?.self) { group in
            for seed in played.prefix(Self.smartSeeds) {
                group.addTask { try? await music.radio(videoId: seed.id) }
            }
            var radios: [[Track]?] = []
            for await radio in group { radios.append(radio) }
            return radios
        }
        guard radios.allSatisfy({ $0 != nil }) else { return nil }
        return Self.interleave([Array(played.prefix(count))] + radios.compactMap(\.self), count: count)
    }

    /// Takes from each list in turn, once per song, up to `count`.
    static func interleave(_ lists: [[Track]], count: Int) -> [Track] {
        var picks: [Track] = []
        var seen = Set<String>()
        for row in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where row < list.count && picks.count < count {
                if seen.insert(list[row].id).inserted { picks.append(list[row]) }
            }
        }
        return picks
    }

    private func add(_ route: Route, title: String, subtitle: String, thumbnail: String?, tracks: [Track]?) {
        guard let tracks else { return }
        guard !tracks.isEmpty else {
            toasts.yield("Nothing to download here")
            return
        }
        index.collections.removeAll { $0.route == route }
        index.collections.insert(DownloadedCollection(route: route, title: title, subtitle: subtitle, thumbnail: thumbnail, tracks: tracks), at: 0)
        changed()
        keepCollectionArtwork()
        announce(title)
    }

    /// Albums' and playlists' own covers, which their songs' artwork doesn't include.
    private func keepCollectionArtwork() {
        let covers = index.collections.compactMap(\.thumbnail)
        Task {
            for cover in covers { await ImagePipeline.shared.keep(cover) }
        }
    }

    /// Shows the album or playlist as waiting meanwhile, so a second tap doesn't ask again.
    private func fetchTracks(of route: Route) async -> [Track]? {
        fetching.insert(route)
        do {
            let tracks = try await tracks(of: route)
            // Nil if Stop downloading took it off meanwhile.
            return fetching.remove(route) == nil ? nil : tracks
        } catch {
            fetching.remove(route)
            toasts.yield("Couldn't download: \(sentence(for: error))")
            return nil
        }
    }

    private func tracks(of route: Route) async throws -> [Track] {
        if case .playlist(let id) = route { return try await music.wholePlaylistTracks(id) }
        return try await music.page(route).headerTracks
    }

    private func status(_ count: Int) -> String {
        if canDownload { return "Downloading \(Formatting.songs(count))" }
        return online == true ? "Waiting for Wi-Fi" : "Waiting for a connection"
    }

    private static func isDue(_ last: Date?) -> Bool {
        last.map { -$0.timeIntervalSinceNow >= refreshEvery } ?? true
    }
}
