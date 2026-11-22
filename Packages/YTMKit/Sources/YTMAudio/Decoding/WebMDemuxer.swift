import AudioToolbox
import Foundation

/// Opus in WebM, as YouTube's 249, 250, 251 and Premium 774 come. Elements of unknown size,
/// as a live encoder writes, are stepped into like any other.
final class WebMDemuxer: PacketSource {
    private(set) var format: SourceFormat?
    private(set) var packets = PacketIndex()
    private(set) var seekPoints: [SeekPoint] = []
    private var walker = ElementWalker(maxHeaderLength: 12, header: EBML.header)
    /// Where the Segment's body starts, which Cues count their Cluster positions from.
    private var segmentStart: Int64 = 0
    private var trackNumber: UInt64?
    /// Nanoseconds a tick of the segment's timestamps lasts.
    private var timecodeScale = 1_000_000.0
    private var durationTicks: Double?
    /// Frames the block ending at `packetCount` packets asks to drop from its end.
    private var discard: (packetCount: Int, frames: Int64)?
    /// Kept from block to block so listing allocates nothing: there is a block every 20 ms.
    private var laceSizes: [Int] = []

    var trailingFrames: Int64 {
        guard let discard, discard.packetCount == packets.count else { return 0 }
        return discard.frames
    }

    func parse(_ bytes: UnsafeRawBufferPointer) throws {
        let action = { [unowned self] (header: ElementWalker.Header, offset: Int64) in
            if header.id == EBML.segment {
                segmentStart = offset
            }
            return Self.action(header)
        }
        try walker.walk(bytes, action: action) { header, body, offset in
            switch header.id {
            case EBML.info: try readInfo(body)
            case EBML.tracks: try readTracks(body)
            case EBML.cues: readCues(body)
            case EBML.simpleBlock: try readBlock(body, at: offset)
            case EBML.blockGroup: try readGroup(body, at: offset)
            default: break
            }
        }
    }

    private static func action(_ header: ElementWalker.Header) -> ElementWalker.Action {
        switch header.id {
        case EBML.segment, EBML.cluster: .enter
        case EBML.info, EBML.tracks, EBML.cues, EBML.simpleBlock, EBML.blockGroup: .read
        default: .skip
        }
    }

    private func readInfo(_ body: UnsafeRawBufferPointer) throws {
        try ElementWalker.forEach(in: body, header: EBML.header) { header, value, _ in
            switch header.id {
            case EBML.timecodeScale: timecodeScale = Double(try EBML.uint(value))
            case EBML.duration: durationTicks = try EBML.float(value)
            default: break
            }
        }
        format?.duration = duration
    }

    private func readTracks(_ body: UnsafeRawBufferPointer) throws {
        try ElementWalker.forEach(in: body, header: EBML.header) { header, entry, _ in
            guard header.id == EBML.trackEntry, format == nil else { return }
            var number: UInt64?
            var codec = ""
            var head: UnsafeRawBufferPointer?
            try ElementWalker.forEach(in: entry, header: EBML.header) { header, value, _ in
                switch header.id {
                case EBML.trackNumber: number = try EBML.uint(value)
                case EBML.codecID: codec = String(decoding: value, as: UTF8.self)
                case EBML.codecPrivate: head = value
                default: break
                }
            }
            guard codec == "A_OPUS", let number, let head else { return }
            trackNumber = number
            format = try Self.opusFormat(head, duration: duration)
        }
        guard format != nil else { throw AudioFailure.unsupported }
    }

    func resumed(at point: SeekPoint) -> any PacketSource {
        let source = WebMDemuxer()
        source.format = format
        source.trackNumber = trackNumber
        source.timecodeScale = timecodeScale
        source.walker = ElementWalker(maxHeaderLength: 12, startingAt: point.offset, header: EBML.header)
        source.packets = PacketIndex(firstFrame: point.frame)
        return source
    }

    /// Each CuePoint's time, in ticks from the first packet's frame, and its Cluster. A damaged index is
    /// ignored rather than failing the file, as only seeks ahead need it.
    private func readCues(_ body: UnsafeRawBufferPointer) {
        var points: [SeekPoint] = []
        do {
            try ElementWalker.forEach(in: body, header: EBML.header) { header, point, _ in
                guard header.id == EBML.cuePoint else { return }
                var time: UInt64?
                var position: UInt64?
                try ElementWalker.forEach(in: point, header: EBML.header) { header, value, _ in
                    switch header.id {
                    case EBML.cueTime: time = try EBML.uint(value)
                    case EBML.cueTrackPositions:
                        try ElementWalker.forEach(in: value, header: EBML.header) { header, value, _ in
                            if header.id == EBML.cueClusterPosition, position == nil {
                                position = try EBML.uint(value)
                            }
                        }
                    default: break
                    }
                }
                // The packet index holds 32-bit offsets, so a position past them is damage.
                guard let time, let position, position <= UInt64(UInt32.max) else { return }
                let offset = Int64(position)
                let frame = Double(time) * timecodeScale * Self.rate / 1e9
                guard frame <= Self.rate * SourceFormat.longestSeconds else { return }
                points.append(SeekPoint(frame: Int64(frame.rounded()), offset: segmentStart + offset))
            }
        } catch {
            return
        }
        seekPoints = SeekPoint.ordered(points)
    }

    private var duration: Double? {
        durationTicks.map { $0 * timecodeScale / 1e9 }
    }

    private func readGroup(_ body: UnsafeRawBufferPointer, at offset: Int64) throws {
        var padding: Int64 = 0
        try ElementWalker.forEach(in: body, header: EBML.header) { header, value, start in
            switch header.id {
            case EBML.block: try readBlock(value, at: offset + Int64(start))
            case EBML.discardPadding: padding = try EBML.int(value)
            default: break
            }
        }
        if padding > 0 {
            discard = (packets.count, Int64((Double(padding) * Self.rate / 1e9).rounded()))
        }
    }

    private func readBlock(_ body: UnsafeRawBufferPointer, at offset: Int64) throws {
        var reader = ByteReader(body)
        guard let trackNumber, try EBML.vint(&reader) == trackNumber else { return }
        try reader.skip(2)
        let lacing = (try reader.uint(1) >> 1) & 3
        laceSizes.removeAll(keepingCapacity: true)
        if lacing != 0 {
            let count = Int(try reader.uint(1)) + 1
            switch lacing {
            case 1:
                for _ in 1..<count {
                    var size = 0
                    var byte: UInt64
                    repeat {
                        byte = try reader.uint(1)
                        size += Int(byte)
                    } while byte == 255
                    laceSizes.append(size)
                }
            case 3 where count > 1:
                var size = Int(try EBML.vint(&reader))
                laceSizes.append(size)
                while laceSizes.count < count - 1 {
                    size += try EBML.signedVint(&reader)
                    laceSizes.append(size)
                }
                // Each size must fit the block, so their sum below cannot overflow.
                guard laceSizes.allSatisfy({ (0...reader.remaining).contains($0) }) else { throw AudioFailure.damaged }
            case 3:
                break
            default:
                laceSizes.append(contentsOf: repeatElement(reader.remaining / count, count: count - 1))
            }
        }
        laceSizes.append(reader.remaining - laceSizes.reduce(0, +))
        for size in laceSizes {
            let start = reader.offset
            let packet = try reader.take(size)
            try packets.append(offset: offset + Int64(start), size: size, frames: Self.frames(ofOpusPacket: packet))
        }
    }

    /// Opus always decodes at 48 kHz.
    static let rate = 48_000.0

    /// The codec from the track's OpusHead (RFC 7845), which also opens the decoder.
    static func opusFormat(_ head: UnsafeRawBufferPointer, duration: Double?) throws -> SourceFormat {
        guard head.count >= 19, head.prefix(8).elementsEqual("OpusHead".utf8) else { throw AudioFailure.damaged }
        let channels = UInt32(head[9])
        // Mapping families past 0 carry more channels in several streams.
        guard head[18] == 0, (1...2).contains(channels) else { throw AudioFailure.unsupported }
        let description = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0
        )
        let preSkip = Int64(head[10]) | Int64(head[11]) << 8
        return SourceFormat(description: description, cookie: Data(head), leadingFrames: preSkip, duration: duration)
    }

    /// Frames in an Opus packet, from its table of contents (RFC 6716 3.1).
    static func frames(ofOpusPacket packet: UnsafeRawBufferPointer) throws -> Int {
        guard let toc = packet.first else { throw AudioFailure.damaged }
        let config = Int(toc >> 3)
        let frameLength = switch config {
        case ..<12: [480, 960, 1_920, 2_880][config & 3]
        case ..<16: [480, 960][config & 1]
        default: [120, 240, 480, 960][config & 3]
        }
        let count: Int
        switch toc & 3 {
        case 0: count = 1
        case 1, 2: count = 2
        default:
            guard packet.count > 1 else { throw AudioFailure.damaged }
            count = Int(packet[1] & 0x3F)
        }
        // A packet holds at most 120 ms.
        guard frameLength * count <= 5_760 else { throw AudioFailure.damaged }
        return frameLength * count
    }
}

enum EBML {
    static let segment: UInt32 = 0x1853_8067
    static let info: UInt32 = 0x1549_A966
    static let timecodeScale: UInt32 = 0x2A_D7B1
    static let duration: UInt32 = 0x4489
    static let tracks: UInt32 = 0x1654_AE6B
    static let trackEntry: UInt32 = 0xAE
    static let trackNumber: UInt32 = 0xD7
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let cues: UInt32 = 0x1C53_BB6B
    static let cuePoint: UInt32 = 0xBB
    static let cueTime: UInt32 = 0xB3
    static let cueTrackPositions: UInt32 = 0xB7
    static let cueClusterPosition: UInt32 = 0xF1
    static let cluster: UInt32 = 0x1F43_B675
    static let simpleBlock: UInt32 = 0xA3
    static let blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1
    static let discardPadding: UInt32 = 0x75A2

    /// An element's ID, kept with its length marker as Matroska writes IDs,
    /// and its size, whose bits all set means unknown.
    static func header(_ bytes: UnsafeRawBufferPointer) throws -> ElementWalker.Header? {
        guard let first = bytes.first else { return nil }
        let idLength = first.leadingZeroBitCount + 1
        guard idLength <= 4 else { throw AudioFailure.damaged }
        guard bytes.count > idLength else { return nil }
        let sizeLength = bytes[idLength].leadingZeroBitCount + 1
        guard sizeLength <= 8 else { throw AudioFailure.damaged }
        guard bytes.count >= idLength + sizeLength else { return nil }
        var reader = ByteReader(bytes)
        let id = UInt32(try reader.uint(idLength))
        let size = try vint(&reader)
        let unknown = size == (1 << (7 * UInt64(sizeLength))) - 1
        return ElementWalker.Header(id: id, length: idLength + sizeLength, size: unknown ? nil : Int64(size))
    }

    /// A variable-length unsigned number, its length marker removed.
    static func vint(_ reader: inout ByteReader) throws -> UInt64 {
        let first = try reader.uint(1)
        let length = UInt8(first).leadingZeroBitCount + 1
        guard length <= 8 else { throw AudioFailure.damaged }
        let rest = try reader.uint(length - 1)
        return (first & (0xFF >> UInt64(length))) << (8 * UInt64(length - 1)) | rest
    }

    /// A lace size difference: the number less half its range.
    static func signedVint(_ reader: inout ByteReader) throws -> Int {
        let start = reader.offset
        let value = try vint(&reader)
        let length = reader.offset - start
        return Int(value) - (1 << (7 * length - 1) - 1)
    }

    static func uint(_ value: UnsafeRawBufferPointer) throws -> UInt64 {
        var reader = ByteReader(value)
        return try reader.uint(value.count)
    }

    static func int(_ value: UnsafeRawBufferPointer) throws -> Int64 {
        guard !value.isEmpty else { return 0 }
        let raw = try uint(value)
        let unused = UInt64(64 - 8 * value.count)
        return Int64(bitPattern: raw << unused) >> Int64(unused)
    }

    static func float(_ value: UnsafeRawBufferPointer) throws -> Double {
        switch value.count {
        case 4: Double(Float(bitPattern: UInt32(try uint(value))))
        case 8: Double(bitPattern: try uint(value))
        default: throw AudioFailure.damaged
        }
    }
}
