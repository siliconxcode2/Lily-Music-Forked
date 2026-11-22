import AVFoundation
import Synchronization
@testable import YTMAudio

/// The app's audio engine rendering offline into memory, as fast as it decodes.
///
/// Rendering offline outruns the player's completion callbacks, so the engine
/// sometimes restarts its player where a real device never would; the checks
/// measure what it scheduled, which is exact regardless.
final class OfflineEngine: Sendable {
    /// As a phone's speaker runs.
    static let rate = 48_000.0
    /// The most the offline graph takes at once.
    static let chunk: AVAudioFrameCount = 4_096
    /// How long a step waits on the download before rendering anyway, as a
    /// device plays a stall as silence.
    static let stallLimit: Duration = .seconds(10)

    struct Buffer: Hashable, Sendable {
        let item: String
        /// A new one starts each time the player does.
        let timeline: Int
        /// Its first frame on the timeline.
        let start: Int64
        /// The item frame it starts with.
        let first: Int64
        let frames: Int
    }

    struct Step: Sendable {
        /// The item heard after the chunk; `length` once its file is complete.
        let heard: String?
        let length: (frames: Int64, rate: Double)?
        let frames: Int
        /// The item heard had ended and the next was still opening.
        let gap: Bool
        let scheduled: [Buffer]
    }

    let engine: PlaybackEngine
    private let received = EventLog()
    private let relay: Task<Void, Never>

    init(cache: URL) {
        let (stream, sink) = AsyncStream.makeStream(of: PlaybackEngine.Stamped.self)
        engine = PlaybackEngine(
            output: .offline(sampleRate: Self.rate), source: HTTPByteSource(),
            cache: AudioCache.Location(directory: cache, limit: 256 << 20), events: sink
        )
        relay = Task { [received] in
            for await stamped in stream {
                received.events.withLock { $0.append(stamped.event) }
            }
        }
    }

    deinit {
        relay.cancel()
        engine.send { $0.shutDown() }
    }

    var events: [AudioEvent] { received.events.withLock { $0 } }

    /// Renders one chunk once the engine has sound ahead of it, or nothing to wait for.
    func step() async -> Step {
        let clock = ContinuousClock()
        let deadline = clock.now + Self.stallLimit
        while !(await state(Self.ready)), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await state { engine in
            // Read before rendering, as a buffer may be reported played by it.
            let scheduled = engine.scheduled.map {
                Buffer(item: $0.track.item.id, timeline: engine.generation, start: $0.start, first: $0.first, frames: $0.frames)
            }
            let graph = engine.graph.engine
            var rendered = Int(Self.chunk)
            if graph.isRunning, let buffer = AVAudioPCMBuffer(pcmFormat: graph.manualRenderingFormat, frameCapacity: Self.chunk),
               (try? graph.renderOffline(Self.chunk, to: buffer)) != nil {
                rendered = Int(buffer.frameLength)
            }
            let heard = engine.heard
            let length = heard.flatMap { track in track.length.flatMap { frames in track.sampleRate.map { (frames, $0) } } }
            return Step(heard: heard?.item.id, length: length, frames: rendered, gap: engine.awaitingNext, scheduled: scheduled)
        }
    }

    private func state<T: Sendable>(_ body: @escaping @Sendable (isolated PlaybackEngine) -> T) async -> T {
        await withCheckedContinuation { continuation in
            engine.send { continuation.resume(returning: body($0)) }
        }
    }

    private static func ready(_ engine: isolated PlaybackEngine) -> Bool {
        guard let producing = engine.producing, !engine.paused, !engine.awaitingNext else { return true }
        return engine.playerRunning && (engine.aheadFrames >= Int(chunk) || producing.finished || engine.fade != nil)
    }
}

private final class EventLog: Sendable {
    let events = Mutex<[AudioEvent]>([])
}
