import Foundation
import YTMCore

/// Timed lyrics come from the Android client, else the web client's text.
enum LyricsChecks {
    static func run(_ report: Report) async {
        await report.check("lyrics") { findings in
            var synced = 0
            for song in Live.songs {
                guard let lyrics = try await Live.api.lyrics(videoId: song.id) else {
                    findings.fail("\(song.title): no lyrics")
                    continue
                }
                findings.expect(lyrics.lines.count >= 10, "\(song.title): \(lyrics.lines.count) lines")
                findings.expect(!lyrics.source.isEmpty, "\(song.title): no source")
                if lyrics.isSynced {
                    synced += 1
                    findings.expect(zip(lyrics.starts, lyrics.starts.dropFirst()).allSatisfy { $0 <= $1 }, "\(song.title): timings out of order")
                    findings.expect(lyrics.starts.last.map { $0 < Double(song.seconds) } ?? false, "\(song.title): a line after the song ends")
                    let middle = lyrics.lines.count / 2
                    findings.expect(lyrics.lineIndex(at: lyrics.starts[middle] + 0.01) == middle, "\(song.title): the line playing isn't found")
                }
                let first = lyrics.lines.first { !$0.isEmpty } ?? ""
                findings.note("\(song.title): \(lyrics.lines.count) lines, \(lyrics.isSynced ? "synced" : "plain"), \(lyrics.source); \"\(first.prefix(40))\"")
            }
            findings.expect(synced > 0, "no song had timed lyrics")
        }
    }
}
