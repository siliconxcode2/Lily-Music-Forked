import Foundation
@testable import YTMAudio
@testable import YTMCore

/// `index [videoId]`: each audio file's seek index, Cues in WebM and sidx in MP4, held against the packets
/// listed from the file's start, so a seek ahead starts on the frame it says.
enum IndexInspect {
    static func show(_ videoId: String) async throws -> Bool {
        let resolver = StreamResolver(innerTube: Live.api.innerTube)
        var exact = true
        for id in videoId.isEmpty ? (Live.songs + [Live.musicVideo]).map(\.id) : [videoId] {
            let response = try PlayerResponse(json: await resolver.player(videoId: id, as: .visionOS))
            for format in response.formats where [251, 140].contains(format.itag) {
                guard let url = format.url.flatMap(URL.init(string:)), HTTP.isAllowed(url) else { continue }
                guard let length = format.contentLength else {
                    exact = false
                    print("\(id) itag \(format.itag): no content length")
                    continue
                }
                // One bad file is reported rather than ending the run.
                do {
                    let file = try await download(url, length: length)
                    let line = try check(file)
                    exact = exact && line.exact
                    print("\(id) itag \(format.itag), \(file.count >> 10) KB: \(line.text)")
                } catch {
                    exact = false
                    print("\(id) itag \(format.itag): \(error)")
                }
            }
        }
        return exact
    }

    /// In ranges, as googlevideo throttles large ones.
    private static func download(_ url: URL, length: Int64) async throws -> Data {
        var file = Data()
        while file.count < length {
            var request = URLRequest(url: url)
            request.setValue(ClientProfile.visionOS.userAgent, forHTTPHeaderField: "User-Agent")
            let end = min(Int64(file.count) + StreamLoader.rangeLength, length)
            request.setValue("bytes=\(file.count)-\(end - 1)", forHTTPHeaderField: "Range")
            let (data, _) = try await HTTP.data(for: request)
            guard !data.isEmpty else { break }
            file.append(data)
        }
        return file
    }

    /// A source resumed at each seek point must list the same packets as the full parse from there on. The
    /// index's times are rounded, so how far its frames are from the listed ones is only reported.
    private static func check(_ file: Data) throws -> (text: String, exact: Bool) {
        try file.withUnsafeBytes { bytes in
            let source = try PacketSources.make(sniffing: bytes)
            try source.parse(bytes)
            let packets = source.packets
            var broken = 0
            var furthest: Int64 = 0
            for point in source.seekPoints {
                // A download cut short, or a damaged index, can put a point past the bytes held.
                guard (0..<Int64(bytes.count)).contains(point.offset) else {
                    broken += 1
                    continue
                }
                let resumed = source.resumed(at: point)
                try resumed.parse(UnsafeRawBufferPointer(rebasing: bytes[Int(point.offset)...]))
                guard let first = (0..<packets.count).first(where: { Int64(packets[$0].offset) >= point.offset }),
                      resumed.packets.count == packets.count - first,
                      (0..<resumed.packets.count).allSatisfy({
                          resumed.packets[$0].offset == packets[first + $0].offset && resumed.packets[$0].frames == packets[first + $0].frames
                      })
                else {
                    broken += 1
                    continue
                }
                furthest = max(furthest, abs(packets.start(of: first) - point.frame))
            }
            let text = "\(source.seekPoints.count) seek points, \(packets.count) packets, \(broken) listing other packets, "
                + "index frames off by up to \(furthest)"
            return (text, !source.seekPoints.isEmpty && broken == 0)
        }
    }
}
