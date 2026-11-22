import Foundation
import Observation
import YTMCore

/// Saved as settings.json two seconds after the last change. Call `load()`
/// once at launch, before anything changes it; the player's `start()` does.
@MainActor @Observable public final class SettingsStore {
    public static let shared = SettingsStore(store: .shared)

    public var value = Settings() {
        didSet {
            guard isLoaded, value != oldValue else { return }
            saving.schedule { [weak self] in self?.write() }
        }
    }

    /// The saved settings have been read, so changes are saved from now on.
    public private(set) var isLoaded = false

    @ObservationIgnored private let store: FileStore
    @ObservationIgnored private let saving = Debounce()
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(store: FileStore) {
        self.store = store
    }

    /// Reads once; later calls wait for the first. A missing or unreadable
    /// file leaves the defaults.
    public func load() async {
        if loading == nil {
            let store = store
            loading = Task { [weak self] in
                let saved = await Self.read(store)
                guard let self else { return }
                if let saved { value = saved }
                isLoaded = true
            }
        }
        await loading?.value
    }

    /// Writes a change still waiting, as when the app leaves the foreground.
    func saveNow() {
        guard saving.isPending else { return }
        saving.cancel()
        write()
    }

    private func write() {
        store.save(value, to: .settings)
    }

    @concurrent
    private static func read(_ store: FileStore) async -> Settings? {
        store.load(Settings.self, from: .settings)
    }
}
