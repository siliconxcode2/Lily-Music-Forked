import Foundation
import Testing
@testable import YTMCore

@Suite struct GoogleAuthTests {
    @Test func buildsSAPISIDAuthorization() {
        let cookie = "SID=a; SAPISID=abc; __Secure-3PAPISID=def"
        let auth = GoogleAuth.authorization(cookie: cookie, origin: "https://music.youtube.com", time: 1_700_000_000)
        // sha1("1700000000 abc https://music.youtube.com").
        #expect(auth == "SAPISIDHASH 1700000000_2f3ec011e870f3fbd0238c090c2062c208cead32 "
            + "SAPISID3PHASH 1700000000_b38b56d67b7362e62fd452ce74b55b7cce306020")
        #expect(GoogleAuth.authorization(cookie: "SID=a", origin: "https://x", time: 0) == nil)
        #expect(GoogleAuth.authorization(cookie: "__Secure-3PAPISID=def", origin: "https://x", time: 1)?.hasPrefix("SAPISIDHASH 1_") == true,
                "SAPISIDHASH falls back to the 3P cookie")
    }

    private func cookie(_ name: String, _ value: String, _ domain: String, expires: Date? = nil) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: "/"]
        if let expires { properties[.expires] = expires }
        return try #require(HTTPCookie(properties: properties))
    }

    @Test func keepsOnlyGoogleAndYouTubeCookiesOnce() throws {
        let header = try #require(GoogleAuth.cookieHeader([
            try cookie("SAPISID", "g", ".google.com"),
            try cookie("SAPISID", "y", ".youtube.com"),
            try cookie("HSID", "h", "accounts.google.com"),
            try cookie("TRACK", "t", ".example.com"),
            try cookie("OLD", "o", ".youtube.com", expires: .distantPast),
        ]))
        let pairs = Set(header.components(separatedBy: "; "))
        #expect(pairs == ["SAPISID=y", "HSID=h"])
        #expect(try GoogleAuth.cookieHeader([cookie("SID", "s", ".youtube.com")]) == nil, "no session cookie to sign with")
    }

    @Test func signsRequestsOnlyWhenSignedIn() async throws {
        let auth = GoogleAuth()
        await auth.signOut()
        #expect(await auth.headers(origin: "https://music.youtube.com") == nil)
        try await auth.signIn(cookies: [try cookie("SAPISID", "abc", ".youtube.com")])
        let headers = try #require(await auth.headers(origin: "https://music.youtube.com"))
        #expect(headers["Cookie"] == "SAPISID=abc")
        #expect(headers["X-Goog-AuthUser"] == "0")
        #expect(headers["X-Origin"] == "https://music.youtube.com")
        #expect(headers["Authorization"]?.hasPrefix("SAPISIDHASH ") == true)
        await auth.signOut()
        #expect(await !auth.isSignedIn)
    }

    private func setCookies(_ lines: [String]) throws -> [HTTPCookie] {
        let url = try #require(URL(string: "https://music.youtube.com/"))
        // As URLSession hands over several Set-Cookie headers: joined by commas.
        return HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": lines.joined(separator: ", ")], for: url)
    }

    @Test func takesRenewedCookiesButNotDeletions() throws {
        let cookie = "SID=a; __Secure-1PSIDTS=old; SAPISID=s"
        let cookies = try setCookies([
            "__Secure-1PSIDTS=new; Domain=.youtube.com; Path=/; Secure; HttpOnly",
            "SIDCC=c; expires=Fri, 19-Nov-2099 10:00:00 GMT; path=/; domain=youtube.com",
            "SID=EXPIRED; Domain=.youtube.com; Expires=Thu, 01-Jan-1970 00:00:10 GMT",
            "SAPISID=gone; Domain=.youtube.com; Max-Age=0",
            "YSC=host-only; Path=/",
            "NID=z; Domain=.google.com",
        ])
        #expect(GoogleAuth.merge(cookie, setting: cookies, now: .now) == "SID=a; __Secure-1PSIDTS=new; SAPISID=s; SIDCC=c")
        #expect(try GoogleAuth.merge(cookie, setting: setCookies(["SID=a; Domain=.youtube.com"]), now: .now) == nil, "nothing changed")
        #expect(try GoogleAuth.merge(cookie, setting: setCookies(["SID=; Domain=.youtube.com"]), now: .now) == nil)
    }

    @Test func takesOnlyTheSameLoginsCookies() async throws {
        let auth = GoogleAuth()
        try await auth.signIn(cookies: [try cookie("SAPISID", "abc", ".youtube.com")])
        let url = try #require(URL(string: "https://music.youtube.com/youtubei/v1/browse"))
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie": "SIDCC=new; Domain=.youtube.com"]
        ))
        await auth.take(response, sent: "SAPISID=xyz")
        #expect(await auth.sessionCookie == "SAPISID=abc", "another login's answer")
        let offSite = try #require(URL(string: "https://lh3.googleusercontent.com/a"))
        let redirected = try #require(HTTPURLResponse(
            url: offSite, statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie": "SIDCC=new; Domain=.youtube.com"]
        ))
        await auth.take(redirected, sent: "SAPISID=abc")
        #expect(await auth.sessionCookie == "SAPISID=abc", "an answer redirected off youtube.com")
        await auth.take(response, sent: "SAPISID=abc")
        #expect(await auth.sessionCookie == "SAPISID=abc; SIDCC=new")
        await auth.signOut()
    }

    @Test func sendsNoWatchTimeWithAnotherLoginsCookie() async throws {
        let auth = GoogleAuth()
        try await auth.signIn(cookies: [try cookie("SAPISID", "abc", ".youtube.com")])
        #expect(await auth.sessionCookie == "SAPISID=abc", "signed in, so only the login can refuse it")
        let api = YTMusic(auth: auth, store: FileStore(directory: .temporaryDirectory.appending(path: "ytm-watch-\(UUID().uuidString)")))
        let url = try #require(URL(string: "https://s.youtube.com/api/stats/watchtime"))
        let ping = WatchTime(url: url, scheduled: [], every: 40, login: PlayReport.login("SAPISID=xyz"))
        let watched = Watched(stretches: [0...1], position: 1, elapsed: .seconds(1), paused: true, last: false)
        let refusal = await #expect(throws: YTMError.self) { try await api.reportWatchTime(ping, watched) }
        #expect(refusal?.kind == .notSignedIn, "refused before anything is sent")
        await auth.signOut()
    }
}
