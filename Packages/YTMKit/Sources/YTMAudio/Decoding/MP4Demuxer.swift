import AudioToolbox
import Foundation

/// AAC in fragmented MP4, as YouTube's 139, 140 and 141 come. `AudioFileStream` would parse these too, but
/// gives a packet split across two pieces of the download no offset in the file, which the index needs.
final class MP4Demuxer: PacketSource {
    /// AAC encoders' usual priming, for files whose edit list does not give it.
    static let defaultPriming: Int64 = 2_112

    private(set) var format: SourceFormat?
    private(set) var packets = PacketIndex()
    private(set) var seekPoints: [SeekPoint] = []
    private var walker = ElementWalker(maxHeaderLength: 16, header: MP4.header)
    private var trackID: UInt64 = 0
    private var framesPerPacket = 0
    /// Each packet's size when fragments leave it out, from the movie's track extends.
    private var defaultSize: UInt64 = 0
    /// The music's length in frames, when the edit list gives it.
    private var editedFrames: Int64?

    var trailingFrames: Int64 {
        guard let format, let editedFrames else { return 0 }
        return max(packets.frames - format.leadingFrames - editedFrames, 0)
    }

    func parse(_ bytes: UnsafeRawBufferPointer) throws {
        try walker.walk(bytes, action: Self.action) { header, body, offset in
            switch header.id {
            case MP4.moov: try readMovie(body)
            case MP4.sidx: readIndex(body, end: offset + Int64(body.count))
            case MP4.moof: try readFragment(body, start: offset - Int64(header.length))
            default: break
            }
        }
    }

    private static func action(_ header: ElementWalker.Header, _: Int64) -> ElementWalker.Action {
        [MP4.moov, MP4.sidx, MP4.moof].contains(header.id) ? .read : .skip
    }

    func resumed(at point: SeekPoint) -> any PacketSource {
        let source = MP4Demuxer()
        source.format = format
        source.trackID = trackID
        source.framesPerPacket = framesPerPacket
        source.defaultSize = defaultSize
        source.editedFrames = editedFrames
        source.walker = ElementWalker(maxHeaderLength: 16, startingAt: point.offset, header: MP4.header)
        source.packets = PacketIndex(firstFrame: point.frame)
        return source
    }

    /// Each fragment's start and time from the segment index (ISO 14496-12 8.16.3), whose offsets count
    /// from its own end. Only an index of fragments is used, and a damaged one is ignored, as only seeks
    /// ahead need it.
    private func readIndex(_ body: UnsafeRawBufferPointer, end: Int64) {
        guard let rate = format?.sampleRate, seekPoints.isEmpty else { return }
        var reader = ByteReader(body)
        var points: [SeekPoint] = []
        do {
            let wide = try reader.uint(1) == 1
            try reader.skip(3)
            guard try reader.uint(4) == trackID else { return }
            let scale = try reader.uint(4)
            var time = try reader.uint(wide ? 8 : 4)
            let first = try reader.uint(wide ? 8 : 4)
            try reader.skip(2)
            guard scale > 0, first <= UInt64(UInt32.max) else { return }
            var offset = end + Int64(first)
            for _ in 0..<(try reader.uint(2)) {
                let reference = try reader.uint(4)
                let duration = try reader.uint(4)
                try reader.skip(4)
                // A reference to another index rather than to media.
                guard reference >> 31 == 0 else { return }
                points.append(SeekPoint(frame: try Self.frames(time, scale: scale, rate: rate), offset: offset))
                time += duration
                offset += Int64(reference & 0x7FFF_FFFF)
            }
        } catch {
            return
        }
        seekPoints = SeekPoint.ordered(points)
    }

    private func readMovie(_ movie: UnsafeRawBufferPointer) throws {
        guard format == nil else { return }
        var movieScale: UInt64 = 0
        if let header = try MP4.child([MP4.mvhd], in: movie) {
            var reader = ByteReader(header)
            try reader.skip(try reader.uint(1) == 1 ? 19 : 11)
            movieScale = try reader.uint(4)
        }
        try ElementWalker.forEach(in: movie, header: MP4.header) { header, trak, _ in
            if header.id == MP4.trak, format == nil {
                try readTrack(trak, movieScale: movieScale)
            }
        }
        guard format != nil else { throw AudioFailure.unsupported }
        guard let extends = try MP4.child([MP4.mvex], in: movie) else { return }
        try ElementWalker.forEach(in: extends, header: MP4.header) { header, trex, _ in
            guard header.id == MP4.trex else { return }
            var reader = ByteReader(trex)
            try reader.skip(4)
            guard try reader.uint(4) == trackID else { return }
            try reader.skip(8)
            defaultSize = try reader.uint(4)
        }
    }

    /// Takes the track if it is the movie's sound, which must be AAC.
    private func readTrack(_ trak: UnsafeRawBufferPointer, movieScale: UInt64) throws {
        guard let handler = try MP4.child([MP4.mdia, MP4.hdlr], in: trak) else { return }
        var reader = ByteReader(handler)
        try reader.skip(8)
        guard try reader.uint(4) == MP4.soun,
              let entries = try MP4.child([MP4.mdia, MP4.minf, MP4.stbl, MP4.stsd], in: trak),
              let media = try MP4.child([MP4.mdia, MP4.mdhd], in: trak),
              let trackHeader = try MP4.child([MP4.tkhd], in: trak) else { return }
        reader = ByteReader(entries)
        try reader.skip(8)
        guard let entry = try MP4.child([MP4.mp4a], in: try reader.take(reader.remaining)) else {
            throw AudioFailure.unsupported
        }
        let cookie = try Self.cookie(entry)
        let description = try Self.aacDescription(cookie: cookie)
        framesPerPacket = Int(description.mFramesPerPacket)
        guard framesPerPacket > 0, description.mSampleRate > 0 else { throw AudioFailure.unsupported }

        reader = ByteReader(trackHeader)
        try reader.skip(try reader.uint(1) == 1 ? 19 : 11)
        trackID = try reader.uint(4)

        reader = ByteReader(media)
        let wide = try reader.uint(1) == 1
        try reader.skip(wide ? 19 : 11)
        let mediaScale = try reader.uint(4)
        let mediaDuration = try reader.uint(wide ? 8 : 4)
        guard mediaScale > 0 else { throw AudioFailure.damaged }

        let rate = description.mSampleRate
        var priming = Self.defaultPriming
        if let edit = try Self.edit(in: trak), movieScale > 0 {
            priming = try Self.frames(edit.start, scale: mediaScale, rate: rate)
            editedFrames = edit.length > 0 ? try Self.frames(edit.length, scale: movieScale, rate: rate) : nil
        }
        let duration = editedFrames.map { Double($0) / rate }
            ?? (mediaDuration > 0 ? Double(mediaDuration) / Double(mediaScale) - Double(priming) / rate : nil)
        format = SourceFormat(description: description, cookie: Data(cookie), leadingFrames: priming, duration: duration)
    }

    /// The first edit that plays media: its start in media ticks, its length in movie ticks.
    private static func edit(in trak: UnsafeRawBufferPointer) throws -> (start: UInt64, length: UInt64)? {
        guard let list = try MP4.child([MP4.edts, MP4.elst], in: trak) else { return nil }
        var reader = ByteReader(list)
        let wide = try reader.uint(1) == 1
        try reader.skip(3)
        for _ in 0..<(try reader.uint(4)) {
            let length = try reader.uint(wide ? 8 : 4)
            let start = try reader.uint(wide ? 8 : 4)
            try reader.skip(4)
            // An empty edit, a gap before the media, has a start of -1.
            if start != (wide ? UInt64.max : UInt64(UInt32.max)) {
                return (start, length)
            }
        }
        return nil
    }

    /// No edit runs past a day, so a longer one is a damaged file.
    private static func frames(_ ticks: UInt64, scale: UInt64, rate: Double) throws -> Int64 {
        let frames = (Double(ticks) * rate / Double(scale)).rounded()
        guard frames <= rate * SourceFormat.longestSeconds else { throw AudioFailure.damaged }
        return Int64(frames)
    }

    /// The elementary stream descriptor, which is the decoder's magic cookie.
    private static func cookie(_ entry: UnsafeRawBufferPointer) throws -> UnsafeRawBufferPointer {
        var reader = ByteReader(entry)
        try reader.skip(8)
        let version = try reader.uint(2)
        // QuickTime's sound descriptions add fields to the ISO one.
        try reader.skip(18 + (version == 1 ? 16 : version == 2 ? 36 : 0))
        guard let descriptor = try MP4.child([MP4.esds], in: try reader.take(reader.remaining)), descriptor.count > 4 else {
            throw AudioFailure.unsupported
        }
        return UnsafeRawBufferPointer(rebasing: descriptor[4...])
    }

    /// The codec the cookie describes; for HE-AAC, the richest layer AudioToolbox decodes.
    private static func aacDescription(cookie: UnsafeRawBufferPointer) throws -> AudioStreamBasicDescription {
        guard let base = cookie.baseAddress else { throw AudioFailure.unsupported }
        var info = AudioFormatInfo(
            mASBD: AudioStreamBasicDescription(
                mSampleRate: 0, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: 0, mBitsPerChannel: 0, mReserved: 0
            ),
            mMagicCookie: base,
            mMagicCookieSize: UInt32(cookie.count)
        )
        var size: UInt32 = 0
        let infoSize = UInt32(MemoryLayout<AudioFormatInfo>.size)
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_FormatList, infoSize, &info, &size) == noErr else {
            throw AudioFailure.unsupported
        }
        var items = [AudioFormatListItem](repeating: AudioFormatListItem(), count: max(Int(size) / MemoryLayout<AudioFormatListItem>.size, 1))
        guard AudioFormatGetProperty(kAudioFormatProperty_FormatList, infoSize, &info, &size, &items) == noErr,
              let first = items.first, first.mASBD.mFormatID != 0 else { throw AudioFailure.unsupported }
        return first.mASBD
    }

    /// Lists a fragment's packets, which lie in the media data after it.
    private func readFragment(_ fragment: UnsafeRawBufferPointer, start: Int64) throws {
        guard format != nil else { throw AudioFailure.damaged }
        try ElementWalker.forEach(in: fragment, header: MP4.header) { header, traf, _ in
            guard header.id == MP4.traf, let trackHeader = try MP4.child([MP4.tfhd], in: traf) else { return }
            var reader = ByteReader(trackHeader)
            let flags = try reader.uint(4)
            guard try reader.uint(4) == trackID else { return }
            let base = flags & 0x1 != 0 ? Int64(clamping: try reader.uint(8)) : start
            try reader.skip(flags & 0x2 != 0 ? 4 : 0)
            try reader.skip(flags & 0x8 != 0 ? 4 : 0)
            let size = flags & 0x10 != 0 ? try reader.uint(4) : defaultSize
            var end = base
            try ElementWalker.forEach(in: traf, header: MP4.header) { header, run, _ in
                guard header.id == MP4.trun else { return }
                end = try readRun(run, base: base, follows: end, defaultSize: size)
            }
        }
    }

    /// Returns where the run's data ends.
    private func readRun(_ run: UnsafeRawBufferPointer, base: Int64, follows end: Int64, defaultSize: UInt64) throws -> Int64 {
        var reader = ByteReader(run)
        let flags = try reader.uint(4)
        let count = try reader.uint(4)
        var offset = end
        if flags & 0x1 != 0 {
            let (moved, overflow) = base.addingReportingOverflow(Int64(Int32(truncatingIfNeeded: try reader.uint(4))))
            guard !overflow else { throw AudioFailure.damaged }
            offset = moved
        }
        try reader.skip(flags & 0x4 != 0 ? 4 : 0)
        for _ in 0..<count {
            try reader.skip(flags & 0x100 != 0 ? 4 : 0)
            let size = flags & 0x200 != 0 ? try reader.uint(4) : defaultSize
            try reader.skip((flags & 0x400 != 0 ? 4 : 0) + (flags & 0x800 != 0 ? 4 : 0))
            try packets.append(offset: offset, size: Int(size), frames: framesPerPacket)
            offset += Int64(size)
        }
        return offset
    }
}

enum MP4 {
    static let moov = code("moov"), moof = code("moof"), mvhd = code("mvhd"), mvex = code("mvex")
    static let trex = code("trex"), trak = code("trak"), tkhd = code("tkhd"), edts = code("edts")
    static let elst = code("elst"), mdia = code("mdia"), mdhd = code("mdhd"), hdlr = code("hdlr")
    static let minf = code("minf"), stbl = code("stbl"), stsd = code("stsd"), mp4a = code("mp4a")
    static let esds = code("esds"), traf = code("traf"), tfhd = code("tfhd"), trun = code("trun")
    static let soun = code("soun"), sidx = code("sidx")

    static func code(_ name: String) -> UInt32 {
        name.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// A size of 1 means a 64-bit size follows; 0 means the box runs to the end of the file.
    static func header(_ bytes: UnsafeRawBufferPointer) throws -> ElementWalker.Header? {
        guard bytes.count >= 8 else { return nil }
        var reader = ByteReader(bytes)
        let size = try reader.uint(4)
        let type = UInt32(try reader.uint(4))
        switch size {
        case 0:
            return ElementWalker.Header(id: type, length: 8, size: nil)
        case 1:
            guard bytes.count >= 16 else { return nil }
            let large = try reader.uint(8)
            guard large >= 16, large <= UInt64(Int64.max) else { throw AudioFailure.damaged }
            return ElementWalker.Header(id: type, length: 16, size: Int64(large) - 16)
        case 8...:
            return ElementWalker.Header(id: type, length: 8, size: Int64(size) - 8)
        default:
            throw AudioFailure.damaged
        }
    }

    /// The body of the box down `path` from `bytes`, taking the first of each type.
    static func child(_ path: [UInt32], in bytes: UnsafeRawBufferPointer) throws -> UnsafeRawBufferPointer? {
        var current = bytes
        for type in path {
            var found: UnsafeRawBufferPointer?
            try ElementWalker.forEach(in: current, header: header) { header, body, _ in
                if found == nil, header.id == type {
                    found = body
                }
            }
            guard let found else { return nil }
            current = found
        }
        return current
    }
}
