import Foundation
import YTMCore

enum RadioChecks {
    static func run(_ report: Report) async {
        await report.check("radio from songs") { findings in
            for song in Live.songs.prefix(2) {
                let tracks = try await Live.api.radio(videoId: song.id)
                findings.audit(tracks, "radio of \(song.title)")
                findings.expect(tracks.count >= 25, "radio of \(song.title): \(tracks.count) tracks")
                let seed = tracks.firstIndex { $0.id == song.id }
                findings.note("\(song.title): \(tracks.count) tracks, \(tracks.filter(\.isVideo).count) videos, seed \(seed.map { "at \($0)" } ?? "absent")")
            }
        }

        await report.check("radio from an artist and an album") { findings in
            let artist = try await Live.api.page(.artist(Live.artist))
            let album = try await Live.api.page(.album(Live.album))
            for (label, id) in [("artist", artist.header?.radioId), ("album", album.header?.radioId)] {
                guard let id else {
                    findings.fail("the \(label) page has no radio")
                    continue
                }
                let tracks = try await Live.api.radio(playlistId: id)
                findings.audit(tracks, "\(label) radio")
                findings.expect(tracks.count >= 25, "\(label) radio: \(tracks.count) tracks")
                findings.note("\(label) radio \(id.prefix(8))…: \(tracks.count) tracks, \(tracks.filter(\.isVideo).count) videos")
            }
        }
    }
}
