import AVFoundation
import Synchronization
import Testing
@testable import YTMAudio

struct PlaybackEngineTests {
    private let first = Fixtures.signal(frames: 48_000, silence: 200)
    private let second = Fixtures.signal(frames: 48_000).map { -$0 }

    /// The engine renders the same samples the decoder gives, past the start's fade-in.
    private func expectSame(_ output: ArraySlice<Float>, _ expected: ArraySlice<Float>, _ comment: Comment) {
        let error = zip(output, expected).map { abs($0 - $1) }.max() ?? .infinity
        #expect(error < 1e-6 && output.count <= expected.count, comment)
    }

    @Test func playsAnItemToItsExactEnd() async throws {
        let file = try Fixtures.opusWebM(first)
        let playback = OfflinePlayback(files: ["one": file])
        let item = try AudioItem.fixture("one", length: file.count)
        playback.engine.send { $0.play(item, from: 0, paused: false, session: 1) }
        let output = await playback.render(seconds: 1.5)
        let decoded = try DecodableFile(file).decode()
        expectSame(output[480..<48_000], decoded[480...], "the item as decoded")
        #expect(output[48_000...].allSatisfy { $0 == 0 }, "nothing after its end")
        #expect(playback.events == [.buffering(true), .started(id: "one"), .buffering(false), .finished])
    }

    @Test func followsOnWithNoGap() async throws {
        let files = ["one": try Fixtures.opusWebM(first), "two": try Fixtures.opusWebM(second)]
        let playback = OfflinePlayback(files: files)
        let one = try AudioItem.fixture("one", length: files["one", default: Data()].count)
        let two = try AudioItem.fixture("two", length: files["two", default: Data()].count)
        playback.engine.send { $0.play(one, from: 0, paused: false, session: 1) }
        playback.engine.send { $0.setNext(two, fade: 0, session: 1) }
        let output = await playback.render(seconds: 2.5)
        let decoded = try DecodableFile(files["one", default: Data()]).decode() + DecodableFile(files["two", default: Data()]).decode()
        expectSame(output[480..<96_000], decoded[480...], "the second item's first frame follows the first's last")
        #expect(playback.events == [.buffering(true), .started(id: "one"), .buffering(false), .advanced(id: "two"), .finished])
    }

    @Test func playsFasterAtASpeed() async throws {
        let file = try Fixtures.opusWebM(Fixtures.signal(frames: 144_000))
        let playback = OfflinePlayback(files: ["one": file])
        let item = try AudioItem.fixture("one", length: file.count)
        playback.engine.send { $0.setSpeed(2) }
        playback.engine.send { $0.play(item, from: 0, paused: false, session: 1) }
        _ = await playback.render(seconds: 0.5)
        // The clock is pinned to the player's frame, so that must run at the speed too.
        let sample = await playback.state { $0.graph.renderedSample()?.sample ?? 0 }
        #expect(abs(Double(sample) - 48_000) < 6_000, "a second of the song in half a second")
        _ = await playback.render(seconds: 1.75)
        #expect(playback.events.contains(.finished), "three seconds of the song in one and a half")
    }

    @Test func seeksToTheExactFrame() async throws {
        let file = try Fixtures.opusWebM(Fixtures.signal(frames: 144_000))
        let playback = OfflinePlayback(files: ["one": file])
        let item = try AudioItem.fixture("one", length: file.count)
        playback.engine.send { $0.play(item, from: 0, paused: false, session: 1) }
        _ = await playback.render(seconds: 0.2)
        playback.engine.send { $0.seek(to: 1.5, session: 1) }
        let output = await playback.render(seconds: 0.5)
        let decoded = try DecodableFile(file).decode(from: 72_000)
        expectSame(output[480...], decoded[480...], "the item from 1.5 s on")
    }

    @Test func crossfadesWithEqualPower() async throws {
        // The first ends in silence, which is cut; the second's leading silence is cut too.
        // The first is longer than the engine schedules ahead, so the fade is planned in time.
        let ending = Fixtures.signal(frames: 228_000) + Array(repeating: 0, count: 12_000)
        let files = ["one": try Fixtures.opusWebM(ending), "two": try Fixtures.opusWebM(Fixtures.signal(frames: 48_000, silence: 2_000))]
        let playback = OfflinePlayback(files: files)
        let one = try AudioItem.fixture("one", length: files["one", default: Data()].count)
        let two = try AudioItem.fixture("two", length: files["two", default: Data()].count, loudnessDB: -6)
        playback.engine.send { $0.play(one, from: 0, paused: false, session: 1) }
        playback.engine.send { $0.setNext(two, fade: 0.5, session: 1) }
        let output = await playback.render(seconds: 6)
        let outgoing = try DecodableFile(files["one", default: Data()]).decode()
        let incoming = try DecodableFile(files["two", default: Data()]).decode()
        // The fade ends where the first item's sound does, and brings in the second's first
        // sound; the codec rings on a little past the one and leads the other.
        let end = (outgoing.lastIndex { abs($0) >= Crossfade.silence } ?? 0) + 1
        let lead = incoming.firstIndex { abs($0) >= Crossfade.silence } ?? 0
        #expect(abs(end - 228_000) < 1_000 && abs(lead - 2_000) < 300)
        let length = 24_000
        let start = end - length
        let gain = pow(10, Float(-6) / 20)
        expectSame(output[480..<start], outgoing[480...], "the first item up to the fade")
        var error: Float = 0
        for frame in 0..<length {
            let angle = Double(frame) / Double(length) * .pi / 2
            let mixed = outgoing[start + frame] * Float(cos(angle)) + incoming[lead + frame] * gain * Float(sin(angle))
            error = max(error, abs(output[start + frame] - mixed))
        }
        #expect(error < 1e-5, "equal-power curves, each item at its own gain")
        let after = incoming[(lead + length)...].map { $0 * gain }
        expectSame(output[end..<end + 10_000], after[...], "the second item on from the fade")
        #expect(playback.events == [.buffering(true), .started(id: "one"), .buffering(false), .advanced(id: "two"), .finished])
    }

    @Test func dropsTheNextWhenASeekFollowsTheSwitch() async throws {
        let files = ["one": try Fixtures.opusWebM(first), "two": try Fixtures.opusWebM(second)]
        let playback = OfflinePlayback(files: files)
        let one = try AudioItem.fixture("one", length: files["one", default: Data()].count)
        let two = try AudioItem.fixture("two", length: files["two", default: Data()].count)
        playback.engine.send { $0.play(one, from: 0, paused: false, session: 1) }
        playback.engine.send { $0.setNext(two, fade: 0, session: 1) }
        while await playback.state({ $0.producing === $0.heard }) {
            _ = await playback.render(seconds: 0.05)
        }
        playback.engine.send { $0.seek(to: 0.5, session: 1) }
        _ = await playback.render(seconds: 1)
        #expect(playback.events.suffix(2) == [.nextDropped, .finished], "the first item plays out, alone")
    }

    @Test func liftsTheBandsTheEqualiserBoosts() async throws {
        let tones = (0..<96_000).map { frame -> Float in
            let time = Double(frame) / Fixtures.rate
            return Float(0.3 * sin(2 * Double.pi * 62 * time) + 0.3 * sin(2 * Double.pi * 1_000 * time))
        }
        let file = try Fixtures.opusWebM(tones)
        let playback = OfflinePlayback(files: ["tones": file])
        let item = try AudioItem.fixture("tones", length: file.count)
        func balance(_ output: [Float]) -> Double {
            let window = output[24_000..<48_000]
            return 10 * log10(goertzel(window, 62) / goertzel(window, 1_000))
        }
        playback.engine.send { $0.play(item, from: 0, paused: false, session: 1) }
        let flat = balance(await playback.render(seconds: 1))
        playback.engine.send { $0.setEqualiser(enabled: true, gains: [0, 12, 0, 0, 0, 0, 0, 0, 0, 0]) }
        playback.engine.send { $0.seek(to: 0, session: 1) }
        let boosted = await playback.render(seconds: 1)
        #expect(abs(balance(boosted) - flat - 12) < 1.5, "62 Hz lifted 12 dB against 1 kHz")
        #expect((boosted.map(abs).max() ?? 2) < 1, "lowered by the boost, so it never clips")
    }

    @Test func pausesWithoutAClickAndResumesWhereItLeftOff() async throws {
        let file = try Fixtures.opusWebM(Fixtures.signal(frames: 144_000))
        let playback = OfflinePlayback(files: ["one": file])
        let item = try AudioItem.fixture("one", length: file.count)
        playback.engine.send { $0.play(item, from: 0, paused: false, session: 1) }
        let before = await playback.render(seconds: 0.5)
        // In one go on the engine's queue, so the player's delayed pause lands after the ramp however busy the
        // machine running the tests.
        let ramp = await playback.state { engine in
            engine.pause()
            return (0..<3).flatMap { _ in OfflinePlayback.piece(engine).left }
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(ramp.suffix(100).allSatisfy { abs($0) < 1e-4 }, "faded out within 50 ms")
        #expect((ramp[240..<480].map(abs).max() ?? 0) > 0.01, "ramped down over several ms rather than cut")
        playback.engine.send { $0.resume() }
        let after = await playback.render(seconds: 0.2)
        let decoded = try DecodableFile(file).decode()
        // The player paused once the ramp ended, so the sound carries on from there.
        let resumed = before.count + ramp.count
        let lag = bestLag(after[4_800..<5_800], in: decoded, at: resumed + 4_800, search: 1_200)
        #expect(abs(lag) <= 1_024, "no more skipped or repeated than one render: \(lag)")
    }

    @Test func normalisesByTheItemsGain() async throws {
        let file = try Fixtures.opusWebM(first)
        let playback = OfflinePlayback(files: ["one": file])
        let item = try AudioItem.fixture("one", length: file.count, loudnessDB: -6)
        playback.engine.send { $0.play(item, from: 0, paused: false, session: 1) }
        let output = await playback.render(seconds: 0.5)
        let decoded = try DecodableFile(file).decode().map { $0 * pow(10, Float(-6) / 20) }
        expectSame(output[480..<24_000], decoded[480...], "the item at -6 dB")
    }

    @Test func normalisationTurnedOffReachesTheItemPlaying() async throws {
        let file = try Fixtures.opusWebM(Fixtures.signal(frames: 288_000))
        let playback = OfflinePlayback(files: ["one": file])
        let item = try AudioItem.fixture("one", length: file.count, loudnessDB: -6)
        playback.engine.send { $0.play(item, from: 0, paused: false, session: 1) }
        let before = await playback.render(seconds: 0.25)
        playback.engine.send { $0.normalise = nil }
        let output = before + (await playback.render(seconds: 5.5))
        let decoded = try DecodableFile(file).decode()
        let gain = pow(10, Float(-6) / 20)
        // What was scheduled plays as it was, at least the few seconds the
        // engine keeps ahead, then a buffer glides to the full level.
        let scheduled = Int((PlaybackEngine.aheadSeconds - PlaybackEngine.bufferSeconds) * Fixtures.rate)
        expectSame(output[480..<scheduled], decoded[480..<scheduled].map { $0 * gain }[...], "at -6 dB until then")
        let glided = Int((0.25 + PlaybackEngine.aheadSeconds + 2 * PlaybackEngine.bufferSeconds) * Fixtures.rate)
        expectSame(output[glided...], decoded[glided...], "then as decoded")
        func largestStep(_ samples: [Float]) -> Float {
            zip(samples[scheduled..<glided], samples[(scheduled + 1)...]).map { abs($1 - $0) }.max() ?? 1
        }
        #expect(largestStep(output) < largestStep(decoded) + 0.01, "with no click")
    }

    @Test func carriesOnFromTheStartAWarmUpFetched() async throws {
        let file = try Fixtures.opusWebM(Fixtures.signal(frames: 480_000))
        let source = RecordingByteSource(files: ["one": file])
        let playback = OfflinePlayback(source: source)
        let item = try AudioItem.fixture("one", length: file.count)
        #expect(file.count > StreamLoader.warmLength)
        playback.engine.send { $0.warm(item) }
        playback.engine.send { $0.play(item, from: 0, paused: false, session: 1) }
        let output = await playback.render(seconds: 0.5)
        while await playback.state({ $0.clock.buffered }) < 1 {
            _ = await playback.render(seconds: 0.1)
        }
        let length = Int64(file.count)
        #expect(source.ranges == [0..<StreamLoader.warmLength, StreamLoader.warmLength..<length], "every byte asked for once")
        let decoded = try DecodableFile(file).decode(limit: 24_000)
        expectSame(output[480..<24_000], decoded[480...], "the item from its first byte")
        playback.engine.send { $0.stop(session: 2) }
        #expect(await playback.state({ $0.clock.buffered }) == 0, "nothing heard")
    }

    @Test func carriesOnFromTheBytesANextItemLetGoHadFetched() async throws {
        // Both long enough that neither ends, nor follows on, while the test looks.
        let long = Fixtures.signal(frames: 480_000)
        let files = ["one": try Fixtures.opusWebM(long), "two": try Fixtures.opusWebM(long.map { -$0 })]
        let two = files["two", default: Data()]
        let half = two.count / 2
        let source = StallingByteSource(files: files, stalling: "two", after: half)
        let playback = OfflinePlayback(source: source)
        let one = try AudioItem.fixture("one", length: files["one", default: Data()].count)
        let next = try AudioItem.fixture("two", length: two.count)
        playback.engine.send { $0.play(one, from: 0, paused: false, session: 1) }
        playback.engine.send { $0.setNext(next, fade: 0, session: 1) }
        for _ in 0..<1_000 where await playback.state({ $0.next?.loader.available ?? 0 }) < Int64(half) {
            try await Task.sleep(for: .milliseconds(1))
        }
        // A skip to the queued item: the engine stops, then plays it.
        playback.engine.send { $0.stop(session: 2, keepingOutput: true) }
        playback.engine.send { $0.play(next, from: 0, paused: false, session: 3) }
        let output = await playback.render(seconds: 0.5)
        while await playback.state({ $0.clock.buffered }) < 1 {
            _ = await playback.render(seconds: 0.1)
        }
        let length = Int64(two.count)
        #expect(source.ranges == [0..<length, Int64(half)..<length], "the bytes it had are not asked for again")
        let decoded = try DecodableFile(two).decode(limit: 24_000)
        expectSame(output[480..<24_000], decoded[480...], "the item from its first byte")
    }

    @Test func reportsAStreamThatWillNotDownload() async throws {
        let stale = try #require(URL(string: "https://rr1.googlevideo.com/videoplayback?itag=251&clen=100&lmt=1&file=gone"))
        let item = AudioItem(id: "gone", url: stale, headers: [:], contentLength: 100, cacheKey: "gone-\(UUID())", loudnessDB: 0) { _ in
            (url: stale, headers: [:])
        }
        let (stream, sink) = AsyncStream.makeStream(of: PlaybackEngine.Stamped.self)
        let cache = AudioCache.Location(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), limit: 1 << 20)
        let engine = PlaybackEngine(output: .offline(sampleRate: 48_000), source: MemoryByteSource(files: [:], refuseFrom: 0), cache: cache, events: sink)
        engine.send { $0.play(item, from: 0, paused: false, session: 1) }
        var events: [AudioEvent] = []
        for await stamped in stream {
            events.append(stamped.event)
            if case .failed = stamped.event { break }
        }
        engine.send { $0.shutDown() }
        #expect(events == [.buffering(true), .failed(id: "gone", message: AudioFailure.refused.message)])
    }
}

/// Holds the first request for `stalling` open after `after` bytes, as a
/// slow network does.
private final class StallingByteSource: ByteSource {
    private let served: MemoryByteSource
    private let stalling: String
    private let after: Int
    /// The held request is kept open here rather than left to end.
    private let state = Mutex<(ranges: [Range<Int64>], held: AsyncThrowingStream<Data, any Error>.Continuation?)>(([], nil))

    init(files: [String: Data], stalling: String, after: Int) {
        served = MemoryByteSource(files: files)
        self.stalling = stalling
        self.after = after
    }

    var ranges: [Range<Int64>] { state.withLock { $0.ranges } }

    func bytes(of url: URL, headers: [String: String], range: Range<Int64>) -> AsyncThrowingStream<Data, any Error> {
        guard url.absoluteString.contains(stalling) else { return served.bytes(of: url, headers: headers, range: range) }
        let first = state.withLock { state -> Bool in
            state.ranges.append(range)
            return state.ranges.count == 1
        }
        guard first, let file = served.files[stalling] else { return served.bytes(of: url, headers: headers, range: range) }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        continuation.yield(file.subdata(in: Int(range.lowerBound)..<after))
        state.withLock { $0.held = continuation }
        return stream
    }
}

/// The power of `samples` at `hz`.
private func goertzel(_ samples: ArraySlice<Float>, _ hz: Double) -> Double {
    let coefficient = 2 * cos(2 * .pi * hz / Fixtures.rate)
    var (previous, earlier) = (0.0, 0.0)
    for sample in samples {
        (previous, earlier) = (Double(sample) + coefficient * previous - earlier, previous)
    }
    return previous * previous + earlier * earlier - coefficient * previous * earlier
}
