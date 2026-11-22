import AudioToolbox
import Foundation

/// Lists where each packet lies in the file, so packets are read from the cache file when decoded
/// rather than held in memory.
protocol PacketSource: AnyObject {
    /// Nil until the container's header has been read.
    var format: SourceFormat? { get }
    var packets: PacketIndex { get }
    /// Codec frames of padding after the music, known once the last packet is read.
    var trailingFrames: Int64 { get }
    /// Where a seek can start listing packets without the bytes before, from the container's index:
    /// WebM's Cues or MP4's sidx, which YouTube puts before the first packet.
    var seekPoints: [SeekPoint] { get }
    /// Reads the next bytes of the file; every byte comes once, in order.
    func parse(_ bytes: UnsafeRawBufferPointer) throws
    /// A source that lists packets from `point` on, given the bytes from its offset. Its padding is never known,
    /// so only this one, fed from the file's start, ever gives the length.
    func resumed(at point: SeekPoint) -> any PacketSource
}

/// A Cluster or fragment's start, and the codec frame of its first packet.
struct SeekPoint {
    let frame: Int64
    let offset: Int64

    /// Only points that move on in both time and place, as a damaged index could send a seek anywhere.
    static func ordered(_ points: [SeekPoint]) -> [SeekPoint] {
        var kept: [SeekPoint] = []
        for point in points where kept.last.map({ point.frame > $0.frame && point.offset > $0.offset }) ?? (point.frame >= 0) {
            kept.append(point)
        }
        return kept
    }
}

struct SourceFormat {
    var description: AudioStreamBasicDescription
    var cookie: Data?
    /// Codec frames before the music: Opus's pre-skip or AAC's priming.
    var leadingFrames: Int64
    /// The container's stated length in seconds, until the true one is known.
    var duration: Double?

    /// No file plays longer than this; one that says so is damaged.
    static let longestSeconds = 24 * 60 * 60.0

    var sampleRate: Double { description.mSampleRate }
    var isOpus: Bool { description.mFormatID == kAudioFormatOpus }
}

/// Eight bytes a packet, so even an hour's mix indexes in under two megabytes.
struct PacketIndex {
    struct Entry {
        let offset: UInt32
        let size: UInt16
        let frames: UInt16
    }

    /// A day of 20 ms packets. A container can list packets in a few bytes
    /// each, so a damaged one could otherwise fill memory with them.
    static let capacity = Int(SourceFormat.longestSeconds) * 50

    private(set) var entries: ContiguousArray<Entry> = []
    /// The codec frame the first packet starts on: 0, unless the list starts at a seek point.
    let firstFrame: Int64
    /// Codec frames in every packet listed.
    private(set) var frames: Int64 = 0

    init(firstFrame: Int64 = 0) {
        self.firstFrame = firstFrame
    }

    var count: Int { entries.count }
    subscript(index: Int) -> Entry { entries[index] }

    mutating func append(offset: Int64, size: Int, frames: Int) throws {
        guard entries.count < Self.capacity else { throw AudioFailure.damaged }
        guard let offset = UInt32(exactly: offset), let size = UInt16(exactly: size), size > 0,
              let frames = UInt16(exactly: frames) else { throw AudioFailure.unsupported }
        entries.append(Entry(offset: offset, size: size, frames: frames))
        self.frames += Int64(frames)
    }

    /// Nil past the packets listed so far.
    func packet(holding frame: Int64) -> (index: Int, start: Int64)? {
        guard frame >= firstFrame else { return nil }
        var start = firstFrame
        for (index, entry) in entries.enumerated() {
            let end = start + Int64(entry.frames)
            if frame < end {
                return (index, start)
            }
            start = end
        }
        return nil
    }

    func start(of index: Int) -> Int64 {
        entries.prefix(index).reduce(firstFrame) { $0 + Int64($1.frames) }
    }

    func index(ofOffset offset: UInt32) -> Int? {
        entries.firstIndex { $0.offset == offset }
    }
}

enum PacketSources {
    static let sniffLength = 8

    static func make(sniffing head: UnsafeRawBufferPointer) throws(AudioFailure) -> any PacketSource {
        guard head.count >= sniffLength else { throw .damaged }
        if head.prefix(4).elementsEqual([0x1A, 0x45, 0xDF, 0xA3]) {
            return WebMDemuxer()
        }
        let box = head[4..<8]
        if box.elementsEqual("ftyp".utf8) || box.elementsEqual("styp".utf8) || box.elementsEqual("moov".utf8) {
            return MP4Demuxer()
        }
        throw .unsupported
    }
}
