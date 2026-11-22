import Foundation

extension YTMusic {
    /// Pings the account's player response's stats URL with its cookie, so the
    /// play shows in its history and shapes its recommendations. Returns where
    /// the play's watch time goes, should YouTube say.
    @concurrent
    public func reportPlay(videoId: String) async throws -> WatchTime? {
        let client = ClientProfile.webRemix
        let cookie = try await statsCookie()
        let player = try await innerTube.post("player", body: ["videoId": videoId], client: client)
        // Both pings carry the same nonce, which ties the watch time to the play.
        let cpn = PlayReport.cpn()
        guard let url = PlayReport.statsURL(player["playbackTracking", "videostatsPlaybackUrl", "baseUrl"].string, client: client.name, cpn: cpn)
        else {
            throw YTMError(.parse, "YouTube didn't say where to report the play.")
        }
        try await PlayReport.ping(url, cookie: cookie)
        return WatchTime(player: player, client: client.name, cpn: cpn, login: PlayReport.login(cookie))
    }

    /// Tells YouTube what of the play was heard since the last ping, as the web player does.
    /// Refused once another account is signed in, as an old play's URL must not go with its cookie.
    @concurrent
    public func reportWatchTime(_ ping: WatchTime, _ watched: Watched) async throws {
        let cookie = try await statsCookie()
        guard PlayReport.login(cookie) == ping.login else {
            throw YTMError(.notSignedIn, "Another account is signed in.")
        }
        try await PlayReport.ping(ping.url(for: watched), cookie: cookie)
    }

    private func statsCookie() async throws -> String {
        guard let cookie = await auth.sessionCookie else {
            throw YTMError(.notSignedIn, "Sign in to keep a YouTube history.")
        }
        return cookie
    }
}

/// Where a play's watch time goes, and when: the web player pings at the scheduled seconds, then at the interval.
public struct WatchTime: Sendable {
    let url: URL
    let scheduled: [Int]
    let every: Int
    /// Tells apart the account that reported the play, without keeping its cookie.
    let login: Int?

    /// When ping `n` is due, since the play started, with ping `n - 1` sent at `sent`.
    public func due(_ n: Int, sent: Duration) -> Duration {
        scheduled.indices.contains(n) ? .seconds(scheduled[n]) : sent + .seconds(max(every, 1))
    }

    /// The ping reporting `watched`. Its numbers need no escaping.
    func url(for watched: Watched) -> URL {
        let seconds = { (value: Double) in String(format: "%.3f", value) }
        var items: [URLQueryItem] = []
        // The last ping may have nothing new to add.
        if !watched.stretches.isEmpty {
            items.append(URLQueryItem(name: "st", value: watched.stretches.map { seconds($0.lowerBound) }.joined(separator: ",")))
            items.append(URLQueryItem(name: "et", value: watched.stretches.map { seconds($0.upperBound) }.joined(separator: ",")))
        }
        items += [
            URLQueryItem(name: "cmt", value: seconds(watched.position)),
            URLQueryItem(name: "rt", value: seconds(watched.elapsed / .seconds(1))),
            URLQueryItem(name: "state", value: watched.paused ? "paused" : "playing"),
        ]
        if watched.last { items.append(URLQueryItem(name: "final", value: "1")) }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.percentEncodedQueryItems = (parts.percentEncodedQueryItems ?? []) + items
        return parts.url ?? url
    }
}

extension WatchTime {
    /// Nil when the player response has no watch-time URL, or one anywhere but youtube.com.
    init?(player: JSON, client: String, cpn: String, login: Int?) {
        let tracking = player["playbackTracking"]
        guard let url = PlayReport.statsURL(tracking["videostatsWatchtimeUrl", "baseUrl"].string, client: client, cpn: cpn) else { return nil }
        let scheduled = tracking["videostatsScheduledFlushWalltimeSeconds"].array.compactMap(\.int)
        self.init(
            url: url, scheduled: scheduled.isEmpty ? [10, 20, 30] : scheduled,
            every: tracking["videostatsDefaultFlushIntervalSeconds"].int ?? 40, login: login
        )
    }
}

/// What a watch-time ping reports.
public struct Watched: Sendable {
    /// Stretches heard since the last ping, in song seconds.
    public var stretches: [ClosedRange<Double>]
    /// Where the sound got to.
    public var position: Double
    /// Since the play started.
    public var elapsed: Duration
    public var paused: Bool
    /// The play has ended.
    public var last: Bool

    public init(stretches: [ClosedRange<Double>], position: Double, elapsed: Duration, paused: Bool, last: Bool) {
        self.stretches = stretches
        self.position = position
        self.elapsed = elapsed
        self.paused = paused
        self.last = last
    }
}

enum PlayReport {
    /// A stats URL from the player response, for the play `cpn`. Nil without one, or when it is
    /// anywhere but youtube.com: it is sent the account's cookie.
    static func statsURL(_ base: String?, client: String, cpn: String) -> URL? {
        guard let base, var parts = URLComponents(string: base), HTTP.isYouTube(parts.host) else { return nil }
        parts.percentEncodedQueryItems = (parts.percentEncodedQueryItems ?? []) + [
            URLQueryItem(name: "ver", value: "2"),
            URLQueryItem(name: "c", value: client),
            URLQueryItem(name: "cpn", value: cpn),
        ]
        return parts.url.flatMap { HTTP.isAllowed($0) ? $0 : nil }
    }

    /// A GET as the web client, with the account's cookie. `HTTP` keeps the URL, which carries the
    /// session's tracking tokens, out of its errors.
    static func ping(_ url: URL, cookie: String) async throws {
        guard HTTP.isYouTube(url.host()) else { throw YTMError(.refused, "The app blocked a request to a site it doesn't use.") }
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = ["User-Agent": ClientProfile.webRemix.userAgent, "Cookie": cookie]
        _ = try await HTTP.data(for: request)
    }

    static func login(_ cookie: String) -> Int? {
        GoogleAuth.login(cookie)?.hashValue
    }

    /// A client playback nonce, from the web player's alphabet.
    static func cpn() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<16).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }
}
