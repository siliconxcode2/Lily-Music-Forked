import Foundation
@testable import YTMAudio
@testable import YTMCore

/// A URL can resolve and still be refused, so the first bytes are fetched and
/// read by the engine's own demuxer.
extension Findings {
    static let probeLength = 64 << 10

    mutating func audit(_ stream: ResolvedStream, _ label: String, seconds: Int?, maxKbps: Int?) {
        let itags: Set<Int> = stream.codec == .opus ? [249, 250, 251, 774] : [140, 141]
        expect(itags.contains(stream.itag), "\(label): itag \(stream.itag) isn't \(stream.codec)")
        expect(HTTP.isAllowed(stream.url), "\(label): a URL the app refuses")
        expect(stream.headers["User-Agent"]?.isEmpty == false, "\(label): no User-Agent to download with")
        expect(stream.contentLength > 0, "\(label): no length")
        if let maxKbps { expect(stream.bitrate <= maxKbps * 1000, "\(label): \(stream.bitrate / 1000) kbps over the \(maxKbps) cap") }
        if let seconds, let duration = stream.duration {
            expect(abs(duration - Double(seconds)) < 2, "\(label): \(duration) s, wanted \(seconds)")
        } else if seconds != nil {
            fail("\(label): no duration")
        }
    }

    /// Returns a line for the notes.
    mutating func probe(_ stream: ResolvedStream, _ label: String) async throws -> String {
        var request = URLRequest(url: stream.url)
        for (name, value) in stream.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-\(Self.probeLength - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await HTTP.data(for: request)
        expect(response.statusCode == 206 && data.count == min(Self.probeLength, Int(stream.contentLength)),
               "\(label): \(response.statusCode) with \(data.count) bytes")
        let source = try data.withUnsafeBytes { bytes in
            let source = try PacketSources.make(sniffing: bytes)
            try source.parse(bytes)
            return source
        }
        let rate = source.format?.sampleRate ?? 0
        let isOpus = source.format?.isOpus == true
        expect(isOpus == (stream.codec == .opus), "\(label): the file isn't \(stream.codec)")
        expect(rate == (isOpus ? 48_000 : 44_100), "\(label): \(rate) Hz")
        expect(source.packets.count > 0, "\(label): no packets in the first 64 KB")
        return "\(stream.badge) itag \(stream.itag), \(stream.contentLength >> 10) KB, \(source.packets.count) packets in 64 KB"
            + (stream.loudnessDb.map { String(format: ", %+.1f dB", $0) } ?? ", no loudness")
    }
}
