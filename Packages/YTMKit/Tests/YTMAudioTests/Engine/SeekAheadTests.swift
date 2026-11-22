import Foundation
import Synchronization
import Testing
@testable import YTMAudio

struct SeekAheadTests {
    private let megabyte = StreamLoader.rangeLength

    /// Starting late in a file plays from its index's nearest Cluster or fragment before the bytes before it arrive,
    /// and still ends on the exact frame once they have, with the file cached whole.
    @Test(arguments: [false, true]) func playsASeekAheadBeforeTheBytesBeforeIt(mp4: Bool) async throws {
        let samples = Fixtures.signal(frames: 960_000)
        // Twenty one-second Clusters, or two fragments with an edit list to cut the end on, padded to span four
        // blocks or more. The Cues put each Cluster a millisecond late and the sidx the second fragment 1,600 frames
        // early, so the sound starts that far from where it was asked for.
        let file = mp4
            ? try Fixtures.aacMP4(samples, rate: Fixtures.rate, edited: true, indexed: true, filler: 2 << 20)
            : try Fixtures.opusWebM(samples, cues: true, filler: 150_000)
        let shift: Int64 = mp4 ? 1_600 : -48
        let length = Int64(file.count)
        #expect(length > 3 * megabyte)
        // Half a second into the first Cluster or fragment of the third block, which leaves more to play than is
        // scheduled ahead, so the decoder moves to the whole file's packets part way through.
        let point = try #require(DecodableFile(file).source.seekPoints.first { $0.offset >= 2 * megabyte })
        #expect(point.offset < 3 * megabyte)
        let start = point.frame + shift + 24_000
        #expect(start < 960_000 - 240_000)
        let source = GatedByteSource(file: file, gated: megabyte)
        let playback = OfflinePlayback(source: source)
        let item = try AudioItem.fixture("one", length: file.count)
        playback.engine.send { $0.play(item, from: Double(start) / Fixtures.rate, paused: false, session: 1) }
        let heard = await playback.render(seconds: 0.5)
        #expect(await playback.state { !($0.heard?.loader.isComplete ?? true) }, "the second megabyte is still held back")
        source.open()
        let output = heard + (await playback.render(seconds: Double(960_000 - start) / Fixtures.rate))
        let ahead = stride(from: 2 * megabyte, to: length, by: Int(megabyte)).map { $0..<min($0 + megabyte, length) }
        #expect(source.ranges == [0..<megabyte, megabyte..<2 * megabyte] + ahead + [megabyte..<2 * megabyte],
                "the seek's block on to the end, then the gap")
        let decoded = try DecodableFile(file).decode(from: start + shift)
        let error = zip(output[480..<decoded.count], decoded[480...]).map { abs($0 - $1) }.max() ?? .infinity
        #expect(error < 1e-6, "the item from where the seek landed, on through the switch to the whole file's packets")
        #expect(output[decoded.count...].allSatisfy { $0 == 0 }, "to its exact end")
        #expect(playback.events.last == .finished)
        let cached = await playback.state { $0.cache.completeFile(for: item.cacheKey, length: length) }
        #expect(try Data(contentsOf: try #require(cached)) == file)
    }

    /// Seeking back from a seek run to bytes held from the start plays the packets listed from there, and the
    /// download goes back to the bytes from the start.
    @Test func seeksBackOutOfASeekRun() async throws {
        let file = try Fixtures.opusWebM(Fixtures.signal(frames: 960_000), cues: true, filler: 150_000)
        let point = try #require(DecodableFile(file).source.seekPoints.first { $0.offset >= 2 * megabyte })
        let playback = OfflinePlayback(source: GatedByteSource(file: file, gated: megabyte))
        let item = try AudioItem.fixture("one", length: file.count)
        playback.engine.send { $0.play(item, from: Double(point.frame + 24_000) / Fixtures.rate, paused: false, session: 1) }
        _ = await playback.render(seconds: 0.5)
        #expect(await playback.state { $0.heard?.loader.readPosition } == point.offset, "the download follows the run")
        playback.engine.send { $0.seek(to: 0.5, session: 1) }
        let output = await playback.render(seconds: 0.5)
        #expect(await playback.state { $0.heard?.loader.readPosition } == 0)
        let decoded = try DecodableFile(file).decode(from: 24_000, limit: 24_000)
        let error = zip(output[480..<24_000], decoded[480...]).map { abs($0 - $1) }.max() ?? .infinity
        #expect(error < 1e-6, "the item from 0.5 s, on the packets listed from the start")
    }
}

/// Holds requests starting at `gated` open until `open`, as a stretch of slow network does.
private final class GatedByteSource: ByteSource {
    private let file: Data
    private let gated: Int64
    private let state = Mutex<(ranges: [Range<Int64>], held: [(Range<Int64>, AsyncThrowingStream<Data, any Error>.Continuation)], isOpen: Bool)>(
        ([], [], false)
    )

    init(file: Data, gated: Int64) {
        self.file = file
        self.gated = gated
    }

    var ranges: [Range<Int64>] { state.withLock { $0.ranges } }

    func bytes(of url: URL, headers: [String: String], range: Range<Int64>) -> AsyncThrowingStream<Data, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        let held = state.withLock { state in
            state.ranges.append(range)
            let held = range.lowerBound == gated && !state.isOpen
            if held {
                state.held.append((range, continuation))
            }
            return held
        }
        if !held {
            serve(range, to: continuation)
        }
        return stream
    }

    func open() {
        for (range, continuation) in state.withLock({ state in
            state.isOpen = true
            defer { state.held = [] }
            return state.held
        }) {
            serve(range, to: continuation)
        }
    }

    private func serve(_ range: Range<Int64>, to continuation: AsyncThrowingStream<Data, any Error>.Continuation) {
        var offset = Int(range.lowerBound)
        let end = Int(min(range.upperBound, Int64(file.count)))
        while offset < end {
            let next = min(offset + 4_096, end)
            continuation.yield(file.subdata(in: offset..<next))
            offset = next
        }
        continuation.finish()
    }
}
