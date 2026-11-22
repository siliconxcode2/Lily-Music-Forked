import Foundation
@testable import YTMCore

/// Each plain-URL client is checked on its own, so a client YouTube has broken
/// shows even while the next one covers for it.
enum StreamChecks {
    static func run(_ report: Report) async {
        for song in Live.songs + [Live.musicVideo] {
            await report.check("stream \(song.name)") { findings in
                var bitrates: [Int] = []
                for quality in AudioQuality.allCases {
                    let stream = try await Live.api.stream(videoId: song.id, quality: quality)
                    let label = "\(quality)"
                    findings.audit(stream, label, seconds: song.seconds, maxKbps: quality.maxKbps)
                    findings.note("\(label): " + (try await findings.probe(stream, label)))
                    bitrates.append(stream.bitrate)
                }
                findings.expect(bitrates == bitrates.sorted(), "bitrates fall as quality rises: \(bitrates)")
            }
        }

        let resolver = StreamResolver(innerTube: Live.api.innerTube)
        for client in ClientProfile.plainStreamClients {
            await report.check("stream client \(client.name)") { findings in
                for song in Live.songs.prefix(2) {
                    let stream = try await resolver.resolve(videoId: song.id, as: client, maxKbps: nil)
                    findings.audit(stream, song.title, seconds: song.seconds, maxKbps: nil)
                    findings.expect(stream.headers["User-Agent"] == client.userAgent, "\(song.title): not downloaded as \(client.name)")
                    findings.note("\(song.title): " + (try await findings.probe(stream, song.title)))
                }
            }
        }
    }
}
