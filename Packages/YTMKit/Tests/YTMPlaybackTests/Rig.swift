import Foundation
import Synchronization
import YTMAudio
@testable import YTMCore
@testable import YTMPlayback

/// Notes an observed change, for `withObservationTracking`'s `onChange`.
final class ObservedChange: Sendable {
    private let changed = Mutex(false)

    var happened: Bool { changed.withLock { $0 } }

    func mark() {
        changed.withLock { $0 = true }
    }
}

@MainActor struct Rig {
    let music = FakeMusic()
    let audio = FakeAudio()
    let lastFM = FakeLastFM()
    let store: FileStore
    let settings: SettingsStore
    let history: LocalHistory
    let player: PlayerController

    init(store: FileStore = FileStore(directory: .temporaryDirectory.appending(path: "ytm-tests-\(UUID().uuidString)"))) {
        self.store = store
        settings = SettingsStore(store: store)
        history = LocalHistory(store: store)
        player = PlayerController(
            music: music, settings: settings, history: history, lastFM: lastFM, audio: audio, store: store, system: false
        )
    }

    /// Lets the tasks the player started run as far as they can, waiting on none.
    func yieldToTasks() async {
        for _ in 0..<50 { await Task.yield() }
    }

    /// Lets the tasks the player started run to their end.
    func settle() async {
        for _ in 0..<3 {
            await yieldToTasks()
            await player.resolving?.value
            await player.queueing?.value
            await player.extending?.value
            await player.autoplay?.value
            await player.pendingPlay?.value
            await player.continuing?.value
        }
    }

    var playing: AudioItem? { audio.played.last?.item }

    /// Plays the item the engine was last given until its first sound.
    func soundStarts() async {
        guard let id = playing?.id else { return }
        player.handle(.started(id: id))
        await settle()
    }
}

@MainActor func started(_ rig: Rig = Rig()) async -> Rig {
    await rig.player.start()
    return rig
}
