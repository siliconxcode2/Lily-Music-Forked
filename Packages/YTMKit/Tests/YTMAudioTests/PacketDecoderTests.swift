import AudioToolbox
import Foundation
import Testing
@testable import YTMAudio

struct DecodableFile {
    let source: any PacketSource
    let file: FileHandle
    let state: PacketDecoder.SourceState

    init(_ data: Data) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try data.write(to: url)
        file = try FileHandle(forReadingFrom: url)
        try FileManager.default.removeItem(at: url)
        let source = try data.withUnsafeBytes { try PacketSources.make(sniffing: $0) }
        try data.withUnsafeBytes { try source.parse($0) }
        self.source = source
        state = PacketDecoder.SourceState(
            packets: source.packets, available: Int64(data.count), complete: true, trailingFrames: source.trailingFrames
        )
    }

    /// The left channel from `frame` on, up to `limit` frames.
    func decode(from frame: Int64 = 0, limit: Int = .max) throws -> [Float] {
        let decoder = try PacketDecoder(source: try #require(source.format), file: file)
        decoder.seek(to: frame)
        var out: [Float] = []
        while out.count < limit, case .frames(let count) = try decoder.supply(state) {
            let taken = min(count, limit - out.count)
            out += UnsafeBufferPointer(start: decoder.samples(0), count: taken)
            decoder.consume(taken)
        }
        return out
    }
}

/// The shift of `signal` against `reference` that matches best, within `search` frames.
func bestLag(_ signal: ArraySlice<Float>, in reference: [Float], at start: Int, search: Int = 200) -> Int {
    (-search...search).min { a, b in
        mismatch(signal, reference, start + a) < mismatch(signal, reference, start + b)
    } ?? 0
}

private func mismatch(_ signal: ArraySlice<Float>, _ reference: [Float], _ start: Int) -> Float {
    zip(signal.indices, signal).reduce(0) { total, pair in
        let index = start + pair.0 - signal.startIndex
        return total + (reference.indices.contains(index) ? abs(pair.1 - reference[index]) : 1)
    }
}

struct PacketDecoderTests {
    /// AudioToolbox's Opus decoder runs `opusDecoderDelay` ahead of libopus:
    /// decoding its own encoder's Opus, the sound must start where it did.
    @Test func cutsOpusToTheExactLengthAndPlace() throws {
        let samples = Fixtures.signal(frames: 48_000, silence: 1_000)
        let decoded = try DecodableFile(Fixtures.opusWebM(samples)).decode()
        #expect(decoded.count == samples.count)
        #expect(decoded.firstIndex { abs($0) > 0.05 } == 1_000)
        // A lossy codec may shift the tone's phase by a few frames, no more.
        #expect(abs(bestLag(samples[2_000..<3_000], in: decoded, at: 2_000)) <= 4)
    }

    @Test func cutsAACToTheExactLengthAndPlace() throws {
        let samples = Fixtures.signal(frames: 44_100, silence: 1_000)
        let encoded = try Fixtures.encode(samples, format: kAudioFormatMPEG4AAC, rate: 44_100)
        #expect(encoded.leadingFrames == Int(MP4Demuxer.defaultPriming))
        let edited = try DecodableFile(Fixtures.aacMP4(samples, edited: true)).decode()
        #expect(edited.count == samples.count, "the edit list gives the length")
        #expect(bestLag(samples[2_000..<3_000], in: edited, at: 2_000) == 0)
        // Without one, as YouTube's, only the priming is known to cut.
        let plain = try DecodableFile(Fixtures.aacMP4(samples)).decode()
        #expect(plain.count == encoded.packets.count * 1_024 - encoded.leadingFrames)
        #expect(bestLag(samples[2_000..<3_000], in: plain, at: 2_000) == 0)
    }

    @Test func seeksToTheExactFrame() throws {
        for data in [try Fixtures.opusWebM(Fixtures.signal(frames: 96_000)), try Fixtures.aacMP4(Fixtures.signal(frames: 96_000))] {
            let file = try DecodableFile(data)
            let whole = try file.decode()
            for target in [0, 1, 12_345, 60_000] {
                let part = try file.decode(from: Int64(target), limit: 3_000)
                #expect(part.count == 3_000)
                #expect(bestLag(part[..<1_000], in: whole, at: target) == 0, "seek to \(target)")
                // AAC is exact after its pre-roll; Opus settles within its 80 ms.
                let error = zip(part, whole[target...]).map { abs($0 - $1) }.max() ?? 0
                #expect(error < (file.source.format?.isOpus == true ? 0.05 : 1e-5))
            }
        }
    }

    private func decode(_ file: DecodableFile, listing packets: [(offset: Int64, size: Int)]) throws -> (frames: Int, then: PacketDecoder.Supply) {
        var state = file.state
        state.packets = PacketIndex()
        for packet in packets {
            try state.packets.append(offset: packet.offset, size: packet.size, frames: 960)
        }
        let decoder = try PacketDecoder(source: try #require(file.source.format), file: file.file)
        var frames = 0
        while true {
            let supply = try decoder.supply(state)
            guard case .frames(let count) = supply else { return (frames, supply) }
            frames += count
            decoder.consume(count)
        }
    }

    @Test func decodesPacketsListedOutOfOrderOneAtATime() throws {
        let file = try DecodableFile(Fixtures.opusWebM(Fixtures.signal(frames: 48_000)))
        let (earlier, later) = (file.source.packets[4], file.source.packets[5])
        // The second ends a byte before the first starts, so one read of both would span -1 bytes.
        let (frames, then) = try decode(file, listing: [
            (Int64(later.offset), Int(later.size)),
            (Int64(earlier.offset), Int(later.offset - earlier.offset) - 1),
        ])
        #expect(frames > 0 && then == .ended)
    }

    @Test func endsAtAPacketPastTheEndOfACompleteFile() throws {
        let file = try DecodableFile(Fixtures.opusWebM(Fixtures.signal(frames: 48_000)))
        let first = file.source.packets[0]
        let (frames, then) = try decode(file, listing: [
            (Int64(first.offset), Int(first.size)), (file.state.available + 10, 100), (Int64(first.offset), Int(first.size)),
        ])
        #expect(frames < 960 && then == .ended, "the packet before it, less the pre-skip, rather than waiting for ever")
    }

    @Test func waitsForBytesNotYetDownloaded() throws {
        let data = try Fixtures.opusWebM(Fixtures.signal(frames: 48_000))
        let file = try DecodableFile(data)
        let decoder = try PacketDecoder(source: try #require(file.source.format), file: file.file)
        var partial = file.state
        partial.available = Int64(file.source.packets[30].offset)
        partial.complete = false
        var frames = 0
        while case .frames(let count) = try decoder.supply(partial) {
            frames += count
            decoder.consume(count)
        }
        #expect(try decoder.supply(partial) == .waiting)
        // The 30 packets the bytes reach, less the pre-skip, part cut and part held back by the decoder.
        #expect(frames == 30 * 960 - 312)
        while case .frames(let count) = try decoder.supply(file.state) {
            frames += count
            decoder.consume(count)
        }
        #expect(frames == 48_000)
        #expect(try decoder.supply(file.state) == .ended)
    }

    /// A seek run's next packet missing from the whole file's list, as a damaged index gives, starts again
    /// where the run had got to.
    @Test func followsAListWithoutTheRunsPacketFromWhereItGotTo() throws {
        let data = try Fixtures.opusWebM(Fixtures.signal(frames: 144_000), cues: true)
        let file = try DecodableFile(data)
        // The Cluster at one second, as the last holds only the final packet.
        let point = try #require(file.source.seekPoints.dropFirst().first)
        let run = file.source.resumed(at: point)
        try data.withUnsafeBytes { try run.parse(UnsafeRawBufferPointer(rebasing: $0[Int(point.offset)...])) }
        let decoder = try PacketDecoder(source: try #require(file.source.format), file: file.file)
        decoder.seek(to: point.frame + 4_800)
        var partial = file.state
        partial.packets = run.packets
        partial.complete = false
        if case .frames(let count) = try decoder.supply(partial) {
            decoder.consume(count)
        }
        let reached = decoder.position
        #expect(reached > point.frame + 4_800)
        decoder.follow(PacketIndex(), from: run.packets)
        var out: [Float] = []
        while case .frames(let count) = try decoder.supply(file.state) {
            out += UnsafeBufferPointer(start: decoder.samples(0), count: count)
            decoder.consume(count)
        }
        let whole = try file.decode(from: reached)
        #expect(out.count == whole.count && reached + Int64(out.count) == 144_000, "to the exact end")
        #expect((zip(out, whole).map { abs($0 - $1) }.max() ?? .infinity) < 1e-6)
    }
}
