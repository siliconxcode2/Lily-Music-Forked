import Foundation
import Testing
@testable import YTMCore

@Test func joinsArtists() {
    #expect(ArtistRef.joined([.init(id: nil, name: "A"), .init(id: nil, name: "B"), .init(id: nil, name: "C")]) == "A, B, C")
}

@Test func badgesPremiumFormatsAtTheirNominalBitrate() throws {
    let url = try #require(URL(string: "https://r1.googlevideo.com/x"))
    func badge(_ itag: Int, _ codec: AudioCodec, _ bitrate: Int) -> String {
        ResolvedStream(
            url: url, headers: [:], itag: itag, codec: codec, contentLength: 1, bitrate: bitrate,
            duration: nil, loudnessDb: nil
        ).badge
    }
    #expect(badge(774, .opus, 284_000) == "OPUS 256")
    #expect(badge(141, .aac, 262_000) == "AAC 256")
    #expect(badge(251, .opus, 135_400) == "OPUS 135")
}

@Test func linksNameEachKindAndSkipPagesWithoutOne() {
    #expect(Track(id: "dQw4w9WgXcQ", title: "").link == "https://music.youtube.com/watch?v=dQw4w9WgXcQ")
    #expect(Card(kind: .song, id: "v", title: "").link == "https://music.youtube.com/watch?v=v")
    #expect(Route.album("MPREb_x").link == "https://music.youtube.com/browse/MPREb_x")
    #expect(Route.playlist("PLx").link == "https://music.youtube.com/playlist?list=PLx")
    #expect(Route.artist("UCx").link == "https://music.youtube.com/channel/UCx")
    #expect(Card(kind: .artist, id: "UCx", title: "").link == Route.artist("UCx").link)
    #expect(Card(kind: .genre, id: "x", title: "").link == nil)
    #expect(Route.home.link == nil)
    #expect(Route.search("x").link == nil)
}

@Test func decodesAPageHeaderSavedBeforeItReadOwnershipAndLibraryState() throws {
    let saved = Data(#"{"label":"Playlist","title":"Road trip","subtitle":"","meta":"12 songs","banner":false}"#.utf8)
    let header = try JSONDecoder().decode(PageHeader.self, from: saved)
    #expect(header.title == "Road trip" && header.editable == nil && header.saved == nil && header.count == nil)
}
