import Foundation
import Testing
@testable import YTMCore

@Suite struct AllowlistTests {
    private func allowed(_ url: String) -> Bool {
        URL(string: url).map(HTTP.isAllowed) ?? false
    }

    @Test func allowsYouTubeHostsOverHTTPS() {
        #expect(allowed("https://music.youtube.com/youtubei/v1/player"))
        #expect(allowed("https://www.youtube.com/s/player/abc/base.js"))
        #expect(allowed("https://rr3---sn-abc.googlevideo.com/videoplayback?x=1"))
        #expect(allowed("https://i.ytimg.com/vi/x/hqdefault.jpg"))
        #expect(allowed("https://lh3.googleusercontent.com/abc=w120-h120"))
        #expect(allowed("https://yt3.ggpht.com/abc=s88"))
        #expect(allowed("https://www.gstatic.com/youtube/media/ytm/images/pbg/liked-music-@576.png"))
        #expect(allowed("https://ws.audioscrobbler.com/2.0/"))
        #expect(allowed("https://www.last.fm/api/auth/?api_key=k&token=t"))
    }

    @Test func blocksEverythingElse() {
        #expect(!allowed("http://music.youtube.com/"), "plain HTTP")
        #expect(!allowed("https://youtube.com.evil.com/"))
        #expect(!allowed("https://evilyoutube.com/"))
        #expect(!allowed("https://example.com/image.jpg"))
        #expect(!allowed("https://accounts.google.com/"))
        #expect(!allowed("https://last.fm/"), "only Last.fm's own two hosts")
        #expect(!allowed("file:///etc/passwd"))
    }

    @Test func wordsFailuresWithoutURLs() {
        let error = YTMError(URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://a.googlevideo.com/x?sig=secret") as Any]))
        #expect(error.kind == .network)
        #expect(!error.message.contains("googlevideo"))
        #expect(YTMError(status: 403).status == 403)
        #expect(YTMError(status: 302).kind == .http)
    }
}

@Suite struct ClientProfileTests {
    @Test func appClientsDescribeTheirDevice() {
        let context = ClientProfile.androidVR.context(hl: "en", gl: "GB", visitorData: "V")
        #expect(context["clientName"] as? String == "ANDROID_VR")
        #expect(context["deviceModel"] as? String == "Quest 3")
        #expect(context["androidSdkVersion"] as? Int == 32)
        #expect(context["visitorData"] as? String == "V")
        #expect(context["userAgent"] as? String == ClientProfile.androidVR.userAgent)
        let web = ClientProfile.webRemix.context(hl: "en", gl: "US", visitorData: nil)
        #expect(web["deviceMake"] == nil && web["visitorData"] == nil)
    }

    @Test func headersNameTheClient() {
        let headers = ClientProfile.webRemix.headers(visitorData: "V")
        #expect(headers["X-YouTube-Client-Name"] == "67")
        #expect(headers["Origin"] == "https://music.youtube.com")
        #expect(headers["Referer"] == "https://music.youtube.com/")
        #expect(headers["X-Goog-Visitor-Id"] == "V")
        let android = ClientProfile.androidMusic.headers(visitorData: nil)
        #expect(android["Origin"] == nil && android["X-Goog-Visitor-Id"] == nil)
        #expect(ClientProfile.visionOS.headers(visitorData: nil)["Origin"] == "https://www.youtube.com")
    }

    @Test func buildsEndpointURLs() {
        let url = ClientProfile.webRemix.url("browse")
        #expect(url?.absoluteString == "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false")
        #expect(ClientProfile.plainStreamClients.map(\.name) == ["VISIONOS", "ANDROID_VR", "IOS"])
    }
}

@Suite struct RefusalsTests {
    @Test func pausesOnlyAfterARunOfRefusals() {
        #expect(Refusals.pause(after: Refusals.run - 1) == nil, "stray ones only retry")
        #expect(Refusals.pause(after: Refusals.run) == .seconds(5))
        #expect(Refusals.pause(after: Refusals.run + 1) == .seconds(10))
        #expect(Refusals.pause(after: .max) == .seconds(40), "capped")
    }

    @Test func anAnswerEndsTheRun() async {
        let refusals = Refusals()
        for refused in Array(repeating: true, count: Refusals.run - 1) + [false] + Array(repeating: true, count: Refusals.run - 1) {
            refusals.answered(refused: refused)
        }
        #expect(await !refusals.waitForTurn())
    }

    @Test func aRunPausesAndAPauseIsOnlyExtended() async {
        // Shorter past the run, so a later refusal would cut the first pause short.
        let refusals = Refusals { $0 >= Refusals.run ? .milliseconds($0 == Refusals.run ? 300 : 1) : nil }
        for _ in 0...Refusals.run { refusals.answered(refused: true) }
        let clock = ContinuousClock()
        let started = clock.now
        #expect(await refusals.waitForTurn())
        #expect(clock.now - started > .milliseconds(200))
    }
}

@Suite struct VisitorDataTests {
    private actor Issuer {
        private(set) var fetches = 0
        func issue() -> String {
            fetches += 1
            return "v\(fetches)"
        }
    }

    @Test func keepsAFreshIDOnlyOnceItWorks() async throws {
        let issuer = Issuer()
        let store = FileStore(directory: .temporaryDirectory.appending(path: "ytm-visitor-\(UUID().uuidString)"))
        let visitor = VisitorData(store: store) { await issuer.issue() }
        #expect(try await visitor.value() == "v1")
        #expect(try await visitor.candidate(replacing: "v1") == "v2")
        #expect(try await visitor.value() == "v1", "a candidate that failed too isn't kept")
        await visitor.adopt("v2", replacing: "v1")
        #expect(try await visitor.value() == "v2")
        #expect(try await visitor.candidate(replacing: "v1") == "v2", "another caller replaced it already")
        await visitor.adopt("v3", replacing: "v1")
        #expect(try await visitor.value() == "v2", "a late adoption changes nothing")
        #expect(await issuer.fetches == 2)
    }

    @Test func forgettingFetchesANewIDAndDropsAnAdoptionStartedBefore() async throws {
        let issuer = Issuer()
        let store = FileStore(directory: .temporaryDirectory.appending(path: "ytm-visitor-\(UUID().uuidString)"))
        let visitor = VisitorData(store: store) { await issuer.issue() }
        #expect(try await visitor.value() == "v1")
        let candidate = try await visitor.candidate(replacing: "v1")
        await visitor.forget()
        await visitor.adopt(candidate, replacing: "v1")
        #expect(try await visitor.value() == "v3", "neither the forgotten ID nor its candidate is sent")
        #expect(store.load(Saved.self, from: .visitor)?.value == "v3")
    }

    @Test func ignoresASavedIDThatIsNoHeader() async throws {
        let issuer = Issuer()
        let store = FileStore(directory: .temporaryDirectory.appending(path: "ytm-visitor-\(UUID().uuidString)"))
        store.save(Saved(value: "a\r\nb", fetched: .now), to: .visitor)
        let visitor = VisitorData(store: store) { await issuer.issue() }
        #expect(try await visitor.value() == "v1")
    }

    /// VisitorData's saved file, in the same shape.
    private struct Saved: Codable, Sendable {
        let value: String
        let fetched: Date
    }

    @Test(.timeLimit(.minutes(1))) func sendsADayOldIDWhileANewOneIsFetched() async throws {
        let issuer = Issuer()
        let store = FileStore(directory: .temporaryDirectory.appending(path: "ytm-visitor-\(UUID().uuidString)"))
        store.save(Saved(value: "old", fetched: .now.addingTimeInterval(-2 * 86_400)), to: .visitor)
        let visitor = VisitorData(store: store) { await issuer.issue() }
        var value = try await visitor.value()
        #expect(value == "old", "no request waits on the refresh")
        while value == "old" {
            await Task.yield()
            value = try await visitor.value()
        }
        #expect(value == "v1")
        #expect(await issuer.fetches == 1)
    }

    @Test func asksAsRustypipesDefaults() {
        #expect(InnerTube.language == "en" && InnerTube.country == "US")
    }
}
