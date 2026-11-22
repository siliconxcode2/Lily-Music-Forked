import AVFoundation
import Synchronization
@testable import YTMAudio

private final class EventLog: Sendable {
    let events = Mutex<[AudioEvent]>([])
}

/// The engine rendering offline, faster than real time, with every event it sends.
final class OfflinePlayback: Sendable {
    let engine: PlaybackEngine
    let rate: Double
    private let received = EventLog()
    private let relay: Task<Void, Never>

    /// Rendering at `rate`, as a device would.
    convenience init(files: [String: Data], rate: Double = Fixtures.rate) {
        self.init(source: MemoryByteSource(files: files), rate: rate)
    }

    init(source: any ByteSource, rate: Double = Fixtures.rate) {
        self.rate = rate
        let (stream, sink) = AsyncStream.makeStream(of: PlaybackEngine.Stamped.self)
        let cache = AudioCache.Location(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), limit: 64 << 20)
        engine = PlaybackEngine(output: .offline(sampleRate: rate), source: source, cache: cache, events: sink)
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

    func state<T: Sendable>(_ body: @escaping @Sendable (isolated PlaybackEngine) -> T) async -> T {
        await withCheckedContinuation { continuation in
            engine.send { continuation.resume(returning: body($0)) }
        }
    }

    /// The left channel of `seconds` rendered.
    func render(seconds: Double) async -> [Float] {
        await renderBoth(seconds: seconds).left
    }

    /// Both channels of `seconds` rendered, each piece once the engine has sound ahead of it.
    func renderBoth(seconds: Double) async -> (left: [Float], right: [Float]) {
        var out: (left: [Float], right: [Float]) = ([], [])
        while out.left.count < Int(seconds * rate) {
            for _ in 0..<500 where !(await state(Self.ready)) {
                try? await Task.sleep(for: .milliseconds(1))
            }
            let piece = await state(Self.piece)
            out.left += piece.left
            out.right += piece.right
        }
        return out
    }

    /// Both channels of the next 1,024 frames, silent if the render failed.
    static func piece(_ engine: isolated PlaybackEngine) -> (left: [Float], right: [Float]) {
        let format = engine.graph.engine.manualRenderingFormat
        guard engine.graph.engine.isRunning, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024),
              (try? engine.graph.engine.renderOffline(1_024, to: buffer)) != nil, let channels = buffer.floatChannelData,
              buffer.format.channelCount == 2
        else { return ([Float](repeating: 0, count: 1_024), [Float](repeating: 0, count: 1_024)) }
        let frames = Int(buffer.frameLength)
        return (Array(UnsafeBufferPointer(start: channels[0], count: frames)), Array(UnsafeBufferPointer(start: channels[1], count: frames)))
    }

    private static func ready(_ engine: isolated PlaybackEngine) -> Bool {
        guard let producing = engine.producing, !engine.paused, !engine.awaitingNext else { return true }
        return engine.playerRunning && (engine.aheadFrames >= 4_096 || producing.finished || engine.fade != nil)
    }
}
