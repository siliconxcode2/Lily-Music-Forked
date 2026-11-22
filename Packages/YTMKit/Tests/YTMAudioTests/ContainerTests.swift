import AudioToolbox
import Foundation
import Testing
@testable import YTMAudio

struct ContainerTests {
    private func parse(_ data: Data, piece: Int) throws -> any PacketSource {
        let source = try data.withUnsafeBytes { try PacketSources.make(sniffing: $0) }
        var offset = 0
        while offset < data.count {
            let end = min(offset + piece, data.count)
            try data[offset..<end].withUnsafeBytes { try source.parse($0) }
            offset = end
        }
        return source
    }

    private func entries(_ source: any PacketSource) -> [[Int]] {
        source.packets.entries.map { [Int($0.offset), Int($0.size), Int($0.frames)] }
    }

    @Test(arguments: [false, true])
    func readsOpusFromWebMInAnyPieces(chunked: Bool) throws {
        let samples = Fixtures.signal(frames: 30_000)
        let file = try Fixtures.opusWebM(samples, chunked: chunked)
        let whole = try parse(file, piece: file.count)
        let format = try #require(whole.format)
        #expect(format.isOpus && format.sampleRate == 48_000 && format.description.mChannelsPerFrame == 2)
        #expect(format.leadingFrames == 312)
        #expect(format.cookie?.prefix(8) == Data("OpusHead".utf8))
        #expect(abs((format.duration ?? 0) - Double(samples.count) / 48_000) < 0.001)
        // The music's length, from the packets less pre-skip and the last block's padding.
        #expect(whole.packets.frames - format.leadingFrames - whole.trailingFrames == Int64(samples.count))
        for piece in [1, 3, 7, 4_096] {
            #expect(try entries(parse(file, piece: piece)) == entries(whole), "pieces of \(piece) bytes")
        }
        // Each entry points at its packet's table of contents: 20 ms CELT frames.
        for entry in whole.packets.entries {
            #expect(file[Int(entry.offset)] >> 3 == 31 && entry.frames == 960)
        }
    }

    @Test func readsLacedBlocks() throws {
        let packets: [[UInt8]] = [[0xFC] + Array(repeating: 1, count: 300), [0xFC, 2, 3]]
        let head = Array("OpusHead".utf8) + [1, 2, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0]
        let entry = EBMLWriter.uint(EBML.trackNumber, 1) + EBMLWriter.element(EBML.codecID, Array("A_OPUS".utf8))
            + EBMLWriter.element(EBML.codecPrivate, head)
        let segment = EBMLWriter.element(EBML.tracks, EBMLWriter.element(EBML.trackEntry, entry))
            + EBMLWriter.element(EBML.cluster, EBMLWriter.element(EBML.simpleBlock, EBMLWriter.block(timecode: 0, packets: packets)))
        let file = Data(EBMLWriter.element(0x1A45_DFA3, []) + EBMLWriter.element(EBML.segment, segment))
        let source = try parse(file, piece: 5)
        #expect(source.packets.entries.map { Int($0.size) } == [301, 3])
        #expect(source.packets.entries.map { file[Int($0.offset) + 1] } == [1, 2])
    }

    @Test func refusesOtherCodecs() throws {
        let entry = EBMLWriter.uint(EBML.trackNumber, 1) + EBMLWriter.element(EBML.codecID, Array("A_VORBIS".utf8))
        let segment = EBMLWriter.element(EBML.tracks, EBMLWriter.element(EBML.trackEntry, entry))
        let file = Data(EBMLWriter.element(0x1A45_DFA3, []) + EBMLWriter.element(EBML.segment, segment))
        #expect(throws: AudioFailure.unsupported) { try parse(file, piece: 64) }
        #expect(throws: AudioFailure.unsupported) {
            try Data("RIFF....WAVE".utf8).withUnsafeBytes { try PacketSources.make(sniffing: $0) }
        }
    }

    /// A source resumed at each point lists the packets the whole file does from there on; the index's
    /// times are rounded, so its frames may be a little off theirs.
    @Test func resumesAtEachSeekPointOfCuesAndSidx() throws {
        let samples = Fixtures.signal(frames: 150_000)
        let files = [try Fixtures.opusWebM(samples, cues: true), try Fixtures.aacMP4(samples, indexed: true)]
        let frames: [[Int64]] = [[48, 48_048, 96_048, 144_048], [0, Int64((try Fixtures.encode(samples, format: kAudioFormatMPEG4AAC, rate: 44_100)
            .packets.count / 2) * 1_024 - 1_600)]]
        for (file, expected) in zip(files, frames) {
            let whole = try parse(file, piece: 333)
            #expect(whole.seekPoints.map(\.frame) == expected)
            for point in whole.seekPoints {
                let resumed = whole.resumed(at: point)
                try file[Int(point.offset)...].withUnsafeBytes { try resumed.parse($0) }
                let first = try #require(whole.packets.entries.firstIndex { Int64($0.offset) >= point.offset })
                #expect(entries(resumed) == Array(entries(whole)[first...]), "from \(point.offset)")
                #expect(resumed.packets.firstFrame == point.frame && abs(whole.packets.start(of: first) - point.frame) <= 1_600)
            }
        }
        #expect(try parse(Fixtures.opusWebM(samples), piece: 333).seekPoints.isEmpty, "no Cues")
    }

    @Test func countsOpusFramesFromTheTableOfContents() throws {
        let cases: [([UInt8], Int)] = [
            ([0x00], 480), ([0x08], 960), ([0x18], 2_880), ([0x60], 480), ([0x68], 960),
            ([0x80], 120), ([0xF8], 960), ([0xF9], 1_920), ([0xFB, 0x03], 2_880),
        ]
        for (packet, frames) in cases {
            #expect(try packet.withUnsafeBytes(WebMDemuxer.frames) == frames, "TOC \(packet)")
        }
        #expect(throws: AudioFailure.damaged) { try [UInt8(0xFB), 0x3F].withUnsafeBytes(WebMDemuxer.frames) }
    }

    // MARK: Damaged files fail cleanly

    private func webM(block: [UInt8]) -> Data {
        let head = Array("OpusHead".utf8) + [1, 2, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0]
        let entry = EBMLWriter.uint(EBML.trackNumber, 1) + EBMLWriter.element(EBML.codecID, Array("A_OPUS".utf8))
            + EBMLWriter.element(EBML.codecPrivate, head)
        let segment = EBMLWriter.element(EBML.tracks, EBMLWriter.element(EBML.trackEntry, entry))
            + EBMLWriter.element(EBML.cluster, EBMLWriter.element(EBML.simpleBlock, block))
        return Data(EBMLWriter.element(0x1A45_DFA3, []) + EBMLWriter.element(EBML.segment, segment))
    }

    @Test func refusesLaceSizesPastTheBlock() throws {
        // EBML lacing, 256 packets: the first 2^56 - 1 bytes, each after it the same.
        let sizes: [UInt8] = [0x01] + Array(repeating: 0xFF, count: 7) + Array(repeating: 0xBF, count: 254)
        let file = webM(block: [0x81, 0, 0, 0x86, 0xFF] + sizes + [0xFC, 1, 2])
        #expect(throws: AudioFailure.damaged) { try parse(file, piece: file.count) }
    }

    private func mp4(then moof: [UInt8]) throws -> Data {
        try Fixtures.aacMP4(Fixtures.signal(frames: 4_096)) + MP4Writer.box("moof", MP4Writer.box("traf", moof))
    }

    @Test func refusesADataOffsetPastTheFile() throws {
        let header = MP4Writer.box("tfhd", [0, 0, 0, 0x01] + MP4Writer.u32(1) + MP4Writer.u64(.max))
        let run = MP4Writer.box("trun", [0, 0, 0, 0x01] + MP4Writer.u32(1) + MP4Writer.u32(8))
        let file = try mp4(then: header + run)
        #expect(throws: AudioFailure.damaged) { try parse(file, piece: file.count) }
    }

    @Test func refusesARunOfMorePacketsThanADay() throws {
        // A byte each, listed in a few bytes.
        let header = MP4Writer.box("tfhd", [0, 0, 0, 0x10] + MP4Writer.u32(1) + MP4Writer.u32(1))
        let run = MP4Writer.box("trun", [0, 0, 0, 0] + MP4Writer.u32(.max))
        let file = try mp4(then: header + run)
        #expect(throws: AudioFailure.damaged) { try parse(file, piece: file.count) }
    }

    @Test func refusesAnEditPastADay() throws {
        let file = try Fixtures.aacMP4(Fixtures.signal(frames: 4_096), edited: true, editStart: 1 << 63)
        #expect(throws: AudioFailure.damaged) { try parse(file, piece: file.count) }
    }

    @Test func refusesABoxLargerThanItsParent() throws {
        let large = MP4Writer.u32(1) + Array("free".utf8) + MP4Writer.u64(UInt64(Int64.max))
        let file = Data(MP4Writer.box("ftyp", Array("dash".utf8)) + MP4Writer.box("moov", MP4Writer.box("free", []) + large))
        #expect(throws: AudioFailure.damaged) { try parse(file, piece: file.count) }
    }

    @Test func readsAACFromFragmentedMP4() throws {
        let samples = Fixtures.signal(frames: 20_000)
        let encoded = try Fixtures.encode(samples, format: kAudioFormatMPEG4AAC, rate: 44_100)
        let file = try Fixtures.aacMP4(samples)
        let source = try parse(file, piece: 777)
        let format = try #require(source.format)
        #expect(format.description.mFormatID == kAudioFormatMPEG4AAC && format.sampleRate == 44_100)
        #expect(format.leadingFrames == MP4Demuxer.defaultPriming)
        #expect(source.packets.count == encoded.packets.count)
        // Offsets are the packets' place in the file, across both fragments.
        for (entry, packet) in zip(source.packets.entries, encoded.packets) {
            #expect(Array(file[Int(entry.offset)..<Int(entry.offset) + Int(entry.size)]) == packet)
        }
        #expect(try entries(parse(file, piece: 1)) == entries(source))
    }
}
