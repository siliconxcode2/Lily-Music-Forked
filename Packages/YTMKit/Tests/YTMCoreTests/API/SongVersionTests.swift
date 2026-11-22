import Foundation
import Testing
@testable import YTMCore

private func track(_ id: String, _ title: String, _ artists: [(id: String, name: String)]) -> Track {
    Track(id: id, title: title, artists: artists.map { ArtistRef(id: $0.id.isEmpty ? nil : $0.id, name: $0.name) })
}

@Suite struct SongVersionTests {
    @Test func matchesAMusicVideoToItsSong() {
        let video = track("mqEZcXdtAUA", "Fever", [("UCbuck", "Buckshot"), ("UCfake", "fakemink")])
        let song = track("FDzYuXpyUTI", "Fever", [("UCbuck", "Buckshot"), ("UCfake", "fakemink")])
        #expect(YTMusic.isSongVersion(of: video, song))
        let byName = track("x", "fever ", [("", "FAKEMINK")])
        #expect(YTMusic.isSongVersion(of: video, byName))
    }

    @Test func keepsEditsAndNamesakes() {
        let video = track("mqEZcXdtAUA", "Fever", [("UCbuck", "Buckshot")])
        #expect(!YTMusic.isSongVersion(of: video, track("f61jlvSDYRc", "Fever (Solo)", [("UCbuck", "Buckshot")])))
        #expect(!YTMusic.isSongVersion(of: video, track("x", "Fever", [("UCpeggy", "Peggy Lee")])))
        let upload = track(
            "STX02ldQjJ4", "Cult Member - U Weren't Here I Really Miss You (ORIGINAL SONG + BEST PART + SLOWED)",
            [("UCupload", "some uploader")]
        )
        #expect(!YTMusic.isSongVersion(of: upload, track("x", "U Weren't Here I Really Miss You", [("UCcult", "Cult Member")])))
    }
}
