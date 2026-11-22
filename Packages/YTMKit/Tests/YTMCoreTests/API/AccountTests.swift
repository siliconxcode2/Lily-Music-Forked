import Foundation
import Testing
@testable import YTMCore

@Suite struct AccountTests {
    private let menu = #"""
        {"actions":[{"openPopupAction":{"popup":{"multiPageMenuRenderer":{"header":
          {"activeAccountHeaderRenderer":{"accountName":{"runs":[{"text":"Alex"}]},"channelHandle":{"runs":[{"text":"@alex"}]},
          "accountPhoto":{"thumbnails":[
            {"url":"https://yt3.ggpht.com/a=s88","width":88,"height":88},
            {"url":"https://yt3.ggpht.com/a=s176","width":176,"height":176}]}}}}}}}]}
        """#

    private func json(_ text: String) throws -> JSON {
        try JSON(data: Data(text.utf8))
    }

    @Test func readsTheAccountMenu() throws {
        let account = try #require(Account(menu: json(menu), guidePhoto: nil))
        #expect(account == Account(name: "Alex", handle: "@alex", photo: "https://yt3.ggpht.com/a=s176-rj"))
        let fromGuide = Account(menu: try json(menu), guidePhoto: "https://yt3.ggpht.com/yti/b=s88-c-k-no-rj")
        #expect(fromGuide?.photo == "https://yt3.ggpht.com/yti/b=s88-c-k-no-rj", "the guide's picture is the current one")
        #expect(Account(menu: try json(#"{"actions":[]}"#), guidePhoto: nil) == nil, "a signed-out menu")
    }

    @Test func readsTheAccountPhoto() throws {
        let guide = try json(#"{"items":[],"userProfile":{"accountPhoto":{"thumbnails":[{"url":"https://yt3.ggpht.com/yti/b=s88-c-k-no-rj"}]}}}"#)
        #expect(Account.photo(guide["userProfile", "accountPhoto", "thumbnails"]) == "https://yt3.ggpht.com/yti/b=s88-c-k-no-rj")
        #expect(Account.photo(.missing) == nil)
    }

    @Test func readsTheSessionFromTheResultsPage() {
        #expect(Account.isSignedIn(page: #"ytcfg.set({"SESSION_INDEX":"0","USER_SESSION_ID":"1234567890"});"#))
        #expect(!Account.isSignedIn(page: #"ytcfg.set({"LOGGED_IN":false});"#))
        #expect(!Account.isSignedIn(page: #"{"USER_SESSION_ID":""}"#))
    }

    @Test func readsTheStatsURLsAndSchedule() throws {
        let player = try json(#"""
            {"playabilityStatus":{"status":"OK"},"playbackTracking":{
              "videostatsPlaybackUrl":{"baseUrl":"https://s.youtube.com/api/stats/playback?ns=yt&docid=abc&ei=a%2Bb"},
              "videostatsWatchtimeUrl":{"baseUrl":"https://s.youtube.com/api/stats/watchtime?ns=yt"},
              "videostatsScheduledFlushWalltimeSeconds":[5,15],"videostatsDefaultFlushIntervalSeconds":30}}
            """#)
        let url = try #require(PlayReport.statsURL(player["playbackTracking", "videostatsPlaybackUrl", "baseUrl"].string, client: "WEB_REMIX", cpn: "nonce"))
        #expect(url.host() == "s.youtube.com")
        #expect(url.query(percentEncoded: true) == "ns=yt&docid=abc&ei=a%2Bb&ver=2&c=WEB_REMIX&cpn=nonce", "the response's own parameters kept as sent")
        #expect(PlayReport.statsURL(nil, client: "WEB_REMIX", cpn: "nonce") == nil)

        let watch = try #require(WatchTime(player: player, client: "WEB_REMIX", cpn: "nonce", login: nil))
        #expect(watch.url.query(percentEncoded: true) == "ns=yt&ver=2&c=WEB_REMIX&cpn=nonce", "the play's own nonce")
        #expect(watch.scheduled == [5, 15] && watch.every == 30)
        let bare = try json(#"{"playbackTracking":{"videostatsWatchtimeUrl":{"baseUrl":"https://s.youtube.com/api/stats/watchtime"}}}"#)
        let defaults = try #require(WatchTime(player: bare, client: "WEB_REMIX", cpn: "nonce", login: nil))
        #expect(defaults.scheduled == [10, 20, 30] && defaults.every == 40, "the web player's own")
        #expect(WatchTime(player: try json(#"{"playabilityStatus":{}}"#), client: "WEB_REMIX", cpn: "nonce", login: nil) == nil)
    }

    @Test func sendsTheCookieOnlyToYouTube() throws {
        #expect(PlayReport.statsURL("https://s.youtube.com/api/stats/playback", client: "WEB_REMIX", cpn: "x") != nil)
        #expect(PlayReport.statsURL("https://s.googlevideo.com/api/stats/playback", client: "WEB_REMIX", cpn: "x") == nil)
        #expect(PlayReport.statsURL("https://evilyoutube.com/api/stats/playback", client: "WEB_REMIX", cpn: "x") == nil)
        let elsewhere = try json(#"{"playbackTracking":{"videostatsWatchtimeUrl":{"baseUrl":"https://evil.example/api/stats/watchtime"}}}"#)
        #expect(WatchTime(player: elsewhere, client: "WEB_REMIX", cpn: "x", login: nil) == nil)
    }

    @Test func pingsOnTheScheduleThenAtTheInterval() throws {
        let url = try #require(URL(string: "https://s.youtube.com/api/stats/watchtime"))
        let watch = WatchTime(url: url, scheduled: [10, 20, 30], every: 40, login: nil)
        #expect(watch.due(0, sent: .zero) == .seconds(10))
        #expect(watch.due(1, sent: .seconds(5)) == .seconds(20), "a pause ping keeps the schedule")
        #expect(watch.due(3, sent: .seconds(31)) == .seconds(71), "then 40 s after the last")
    }

    @Test func reportsEachStretchHeard() throws {
        let url = try #require(PlayReport.statsURL("https://s.youtube.com/api/stats/watchtime?ns=yt", client: "WEB_REMIX", cpn: "nonce"))
        let watch = WatchTime(url: url, scheduled: [], every: 40, login: nil)
        func query(_ stretches: [ClosedRange<Double>], last: Bool) -> [String: String] {
            let watched = Watched(stretches: stretches, position: 64.25, elapsed: .milliseconds(20_500), paused: false, last: last)
            let items = URLComponents(url: watch.url(for: watched), resolvingAgainstBaseURL: false)?.queryItems ?? []
            return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        }
        let ping = query([0...12.5, 60...64.25], last: false)
        #expect(ping["cpn"] == "nonce")
        #expect(ping["st"] == "0.000,60.000")
        #expect(ping["et"] == "12.500,64.250")
        #expect(ping["cmt"] == "64.250")
        #expect(ping["rt"] == "20.500")
        #expect(ping["state"] == "playing")
        #expect(ping["final"] == nil)

        let last = query([], last: true)
        #expect(last["final"] == "1")
        #expect(last["st"] == nil, "nothing new heard")
        #expect(last["cmt"] == "64.250")
    }

    @Test func makesNoncesLikeTheWebPlayer() {
        let (a, b) = (PlayReport.cpn(), PlayReport.cpn())
        #expect(a.count == 16)
        #expect(a.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        #expect(a != b, "random each time")
    }
}
