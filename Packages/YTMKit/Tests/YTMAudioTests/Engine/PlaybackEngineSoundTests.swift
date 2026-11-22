import Foundation
import Testing
@testable import YTMAudio

/// The sound unit after the mixer, rendered through the whole engine.
struct PlaybackEngineSoundTests {
    @Test func turnsAQuietItemUpOnlySoFar() async throws {
        let file = try Fixtures.opusWebM(Fixtures.signal(frames: 48_000, silence: 200))
        let playback = OfflinePlayback(files: ["one": file])
        let item = try AudioItem.fixture("one", length: file.count, loudnessDB: 6)
        playback.engine.send { $0.play(item, from: 0, paused: false, session: 1) }
        let output = await playback.render(seconds: 0.5)
        let decoded = try DecodableFile(file).decode()
        let error = zip(output[480..<24_000], decoded[480...]).map { abs($0 - $1 * PlaybackEngine.maxBoost) }.max() ?? 1
        #expect(error < 1e-6, "+3 dB, not +6")
    }

    /// The left side silent once the 50 ms ramp has passed, and the right untouched.
    private func expectRightOnly(_ output: (left: [Float], right: [Float]), _ file: Data) throws {
        let decoded = try DecodableFile(file).decode()
        #expect(output.left[..<2_400].contains { abs($0) > 0.01 }, "faded rather than cut")
        #expect(output.left[2_400...].allSatisfy { $0 == 0 }, "the left side silent once 50 ms have passed")
        let error = zip(output.right[480..<24_000], decoded[480...]).map { abs($0 - $1) }.max() ?? 1
        #expect(error < 1e-6, "the right side at full level")
    }

    @Test func balanceRampsToOneSide() async throws {
        let file = try Fixtures.opusWebM(Fixtures.signal(frames: 48_000))
        let playback = OfflinePlayback(files: ["one": file])
        let item = try AudioItem.fixture("one", length: file.count)
        playback.engine.send { $0.setStereo(crossfeed: false, mono: false, balance: 1) }
        playback.engine.send { $0.play(item, from: 0, paused: false, session: 1) }
        try expectRightOnly(await playback.renderBoth(seconds: 0.5), file)
    }

    @Test func keepsTheSoundThroughARebuild() async throws {
        let file = try Fixtures.opusWebM(Fixtures.signal(frames: 48_000))
        let playback = OfflinePlayback(files: ["one": file])
        let item = try AudioItem.fixture("one", length: file.count)
        playback.engine.send { $0.setStereo(crossfeed: false, mono: false, balance: 1) }
        playback.engine.send { $0.rebuildGraph() }
        playback.engine.send { $0.play(item, from: 0, paused: false, session: 1) }
        try expectRightOnly(await playback.renderBoth(seconds: 0.5), file)
    }

    @Test func followsTheOutputsRate() async throws {
        let file = try Fixtures.opusWebM(Fixtures.signal(frames: 48_000))
        let playback = OfflinePlayback(files: ["one": file], rate: 44_100)
        let item = try AudioItem.fixture("one", length: file.count)
        playback.engine.send { $0.setStereo(crossfeed: false, mono: false, balance: 1) }
        playback.engine.send { $0.play(item, from: 0, paused: false, session: 1) }
        let output = await playback.renderBoth(seconds: 0.5)
        #expect(output.left[..<2_200].contains { abs($0) > 0.01 })
        #expect(output.left[2_210...].allSatisfy { $0 == 0 }, "50 ms at 44.1 kHz, 2,205 frames")
        #expect((output.right[2_210...].map(abs).max() ?? 0) > 0.35, "the right side still sounding")
    }

    @Test func limitsABoostedItemToFullScale() async throws {
        let file = try Fixtures.opusWebM(Fixtures.signal(frames: 48_000).map { $0 * 2.3 })
        let playback = OfflinePlayback(files: ["one": file])
        let item = try AudioItem.fixture("one", length: file.count, loudnessDB: 6)
        playback.engine.send { $0.play(item, from: 0, paused: false, session: 1) }
        let output = await playback.render(seconds: 1)
        #expect(output.allSatisfy { abs($0) <= 1 }, "never past full scale")
        #expect(output.contains { abs($0) > 0.99 }, "but reaching it")
    }

    @Test func startsASeekFromNoLimiting() async throws {
        // Loud enough for the first half-second that the boost is limited, then within full scale.
        let signal = Fixtures.signal(frames: 96_000).enumerated().map { $0 < 24_000 ? $1 * 2.3 : $1 }
        let file = try Fixtures.opusWebM(signal)
        let playback = OfflinePlayback(files: ["one": file])
        let item = try AudioItem.fixture("one", length: file.count, loudnessDB: 6)
        playback.engine.send { $0.play(item, from: 0, paused: false, session: 1) }
        _ = await playback.render(seconds: 0.4)
        playback.engine.send { $0.seek(to: 1, session: 1) }
        let output = await playback.render(seconds: 0.3)
        let decoded = try DecodableFile(file).decode(from: 48_000)
        let error = zip(output[480..<12_000], decoded[480...]).map { abs($0 - $1 * PlaybackEngine.maxBoost) }.max() ?? 1
        #expect(error < 1e-6, "boosted in full, not still held down by what came before")
    }
}
