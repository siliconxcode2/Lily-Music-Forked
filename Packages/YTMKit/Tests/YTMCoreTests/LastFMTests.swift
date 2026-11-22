import Foundation
import Testing
@testable import YTMCore

@Suite struct LastFMRequestTests {
    @Test func signsParametersInNameOrder() {
        var params: LastFMAPI.Params = [("token", "tok\u{e9}"), ("method", "auth.getSession"), ("api_key", "key")]
        LastFMAPI.sign(&params, secret: "secret")
        // md5 of "api_keykeymethodauth.getSessiontokentoké" + "secret".
        #expect(params.map(\.name) == ["api_key", "method", "token", "api_sig"])
        #expect(params.last?.value == "d918bc2b2785863c1487e7a79435acb2")
    }

    @Test func signsABatchByteOrdered() {
        var params: LastFMAPI.Params = [
            ("track[0]", "Jóga&Co =1"), ("timestamp[0]", "1700000000"), ("sk", "SK"),
            ("method", "track.scrobble"), ("artist[0]", "Björk"), ("api_key", "K"),
        ]
        LastFMAPI.sign(&params, secret: "S3cr3t")
        // Computed with `md5 -s` over the names and values in byte order, then the secret.
        #expect(params.last?.value == "d1fb4cc015330dc6598dfb4d2690839c")
    }

    @Test func encodesFormsAsBrowsersDo() {
        let body = LastFMAPI.form([("a b", "Jóga&Co =1*~"), ("x", "")])
        #expect(String(decoding: body, as: UTF8.self) == "a+b=J%C3%B3ga%26Co+%3D1*%7E&x=")
    }

    @Test func readsErrorCodesAsYTMNativeDoes() {
        #expect(LastFMAPI.failure(code: 4, message: "", method: "auth.getSession") == .rejected("Last.fm error 4: "))
        #expect(LastFMAPI.failure(code: 4, message: "", method: "track.scrobble") == .failed("Last.fm error 4: "))
        #expect(LastFMAPI.failure(code: 15, message: "", method: "track.scrobble") == .failed("Last.fm error 15: "))
        #expect(LastFMAPI.failure(code: 6, message: "x", method: "track.scrobble") == .rejected("Last.fm error 6: x"))
        #expect(LastFMAPI.failure(code: 9, message: "", method: "track.scrobble") == .signedOut)
        #expect(LastFMAPI.failure(code: 14, message: "", method: "auth.getSession") == .notYetAllowed)
        #expect(LastFMAPI.failure(code: 10, message: "", method: "auth.getToken") == .invalidKeys)
        #expect(LastFMAPI.failure(code: 11, message: "", method: "track.scrobble") == .failed("Last.fm error 11: "))
    }

    @Test func readsWhyPlaysWereIgnored() throws {
        let one = try JSON(data: Data(##"{"scrobbles":{"scrobble":{"ignoredMessage":{"code":"5","#text":"Daily scrobble limit exceeded"}},"@attr":{"accepted":0,"ignored":1}}}"##.utf8))
        #expect(LastFMAPI.ignored(one) == ["code 5: Daily scrobble limit exceeded"])
        let many = try JSON(data: Data(##"{"scrobbles":{"scrobble":[{"ignoredMessage":{"code":"0","#text":""}},{"ignoredMessage":{"code":"3","#text":"Timestamp too old"}}]}}"##.utf8))
        #expect(LastFMAPI.ignored(many) == ["code 3: Timestamp too old"])
        #expect(LastFMAPI.ignored(try JSON(data: Data("{}".utf8))).isEmpty, "an odd reply")
    }

    @Test func playsTakeTheFirstArtistAndNeedATitle() {
        let start = Date(timeIntervalSince1970: 1_700_000_000.7)
        let track = Track(
            id: "v", title: "Song", artists: [ArtistRef(id: nil, name: "A"), ArtistRef(id: nil, name: "B")],
            album: AlbumRef(id: "MPRE", name: "Album"), duration: 200
        )
        #expect(LastFM.Play(track, at: start) == LastFM.Play(artist: "A", track: "Song", album: "Album", duration: 200, timestamp: 1_700_000_000))
        #expect(LastFM.Play(Track(id: "v", title: "Song"), at: start) == nil, "no artist")
        #expect(LastFM.Play(Track(id: "v", title: "", artists: [ArtistRef(id: nil, name: "A")]), at: start) == nil)
    }
}

@Suite struct PendingScrobblesTests {
    private func play(_ n: Int) -> LastFM.Play {
        LastFM.Play(artist: "A", track: String(n), timestamp: Int64(n))
    }

    @Test func keepsPendingPlaysInOrderWithinTheLimit() {
        let limit = LastFM.Pending.limit, batchSize = LastFM.Pending.batchSize
        var pending = LastFM.Pending()
        for n in 0..<limit + 2 { pending.push(play(n)) }
        #expect(pending.plays.count == limit)
        let batch = pending.batch(one: false)
        #expect(batch.count == batchSize)
        #expect(batch.first?.timestamp == 2, "the oldest were dropped")
        #expect(pending.batch(one: true).count == 1)

        // A new play pushes out the oldest while the batch is on its way.
        pending.push(play(limit + 2))
        pending.remove(batch)
        #expect(pending.batch(one: true).first?.timestamp == Int64(2 + batchSize), "only the sent plays are gone")
        // The pushed-out play was one of the batch, so one fewer goes.
        #expect(pending.plays.count == limit - batchSize + 1)

        pending.hold(for: "a")
        #expect(!pending.isEmpty, "untagged plays from before go to the account")
        pending.hold(for: "a")
        #expect(!pending.isEmpty, "the same account keeps its plays")
        pending.hold(for: "b")
        #expect(pending.isEmpty, "another account gets none of them")
    }

    @Test func survivesASaveAndLoad() throws {
        var pending = LastFM.Pending()
        pending.push(play(1))
        pending.hold(for: "a")
        let loaded = try JSONDecoder().decode(LastFM.Pending.self, from: JSONEncoder().encode(pending))
        #expect(loaded.plays == pending.plays && loaded.account == "a")
    }
}
