import Foundation
import os
import Synchronization

/// Signed-in requests YouTube refused in a row, and until when the rest wait,
/// as it refuses an account's requests in runs.
final class Refusals: Sendable {
    /// Refusals in a row before signed-in requests pause.
    static let run = 6
    private static let log = Logger(subsystem: "Lily", category: "InnerTube")

    private let state = Mutex<(run: Int, pausedUntil: ContinuousClock.Instant?)>((0, nil))
    /// Shortened by tests, so a run's pause can be waited out.
    private let pause: @Sendable (Int) -> Duration?

    init(pause: @escaping @Sendable (Int) -> Duration? = Refusals.pause(after:)) {
        self.pause = pause
    }

    /// How long signed-in requests wait after `run` refusals in a row: 5 s at
    /// `Refusals.run`, doubling up to 40 s.
    static func pause(after run: Int) -> Duration? {
        run >= Self.run ? .seconds(5 << min(run - Self.run, 3)) : nil
    }

    /// Waits out a pause in signed-in requests, returning whether there was one.
    func waitForTurn() async -> Bool {
        guard let until = state.withLock({ $0.pausedUntil }), until > .now else { return false }
        try? await Task.sleep(until: until)
        return true
    }

    /// Counts a signed-in request YouTube answered, `refused` or otherwise.
    func answered(refused: Bool) {
        let started: Duration? = state.withLock { state in
            state.run = refused ? state.run + 1 : 0
            guard let pause = self.pause(state.run) else { return nil }
            let until = ContinuousClock.now + pause
            // Only ever extended, so a shorter pause never cuts a longer one short.
            guard state.pausedUntil.map({ $0 < until }) ?? true else { return nil }
            state.pausedUntil = until
            return pause
        }
        if let started {
            Self.log.warning("YouTube keeps refusing signed-in requests; pausing them for \(started.components.seconds, privacy: .public) s")
        }
    }
}
