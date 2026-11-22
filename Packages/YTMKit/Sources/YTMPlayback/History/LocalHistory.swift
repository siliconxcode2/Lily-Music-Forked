import Foundation
import Observation
import YTMCore

/// History is saved two seconds after the last play, searches at once as they are
/// tiny. Load both once at launch with `load()` (the player's `start()` does).
@MainActor @Observable public final class LocalHistory {
    public static let shared = LocalHistory(store: .shared)

    /// Newest first, one entry per song.
    public private(set) var history = PlayHistory()
    /// Newest first.
    public private(set) var searches = RecentSearches()

    @ObservationIgnored private let store: FileStore
    @ObservationIgnored private let saving = Debounce()
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(store: FileStore) {
        self.store = store
    }

    /// Reads both files off the main actor, once; later calls wait for the first.
    public func load() async {
        if loading == nil {
            let store = store
            loading = Task { [weak self] in
                let (history, searches) = await Self.read(store)
                guard let self else { return }
                // Plays recorded before the file was read come first, and their heard state wins over the file's.
                if let history {
                    let recorded = Set(self.history.tracks.map(\.id))
                    self.history = PlayHistory(
                        tracks: self.history.tracks + history.tracks,
                        skipped: self.history.skipped.union(history.skipped.subtracting(recorded))
                    )
                }
                if let searches { self.searches = searches }
            }
        }
        await loading?.value
    }

    /// For when signed out or with the YouTube history off; nil when nothing has played.
    public var page: Page? {
        guard !history.tracks.isEmpty else { return nil }
        return Page(
            header: PageHeader(label: "Recently played", title: "History", meta: Formatting.songs(history.tracks.count)),
            sections: [.tracks(TrackSection(title: "", tracks: history.tracks, mode: .section))]
        )
    }

    public func recordSearch(_ query: String) {
        searches.record(query)
        store.save(searches, to: .searches)
    }

    public func removeSearch(_ query: String) {
        searches.remove(query)
        store.save(searches, to: .searches)
    }

    /// Writes plays still waiting, as when the app leaves the foreground.
    func saveNow() {
        guard saving.isPending else { return }
        saving.cancel()
        store.save(history, to: .history)
    }

    /// Only the player records plays, as each song's sound starts.
    func record(_ track: Track) {
        history.record(track)
        saveSoon()
    }

    /// Lets the play into Home's Speed dial, once it has been heard long enough to count.
    func markHeard(_ id: String) {
        history.markHeard(id)
        saveSoon()
    }

    private func saveSoon() {
        saving.schedule { [weak self] in
            guard let self else { return }
            store.save(history, to: .history)
        }
    }

    @concurrent
    private static func read(_ store: FileStore) async -> (PlayHistory?, RecentSearches?) {
        (store.load(PlayHistory.self, from: .history), store.load(RecentSearches.self, from: .searches))
    }
}
