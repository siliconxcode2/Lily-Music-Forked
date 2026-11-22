import CryptoKit
import Foundation

extension LastFM {
    /// From the `LASTFM_API_KEY` and `LASTFM_API_SECRET` build settings.
    struct Keys: Sendable {
        var apiKey: String
        var apiSecret: String

        /// Nil in a build without them, whose settings expand to nothing.
        static let builtIn: Keys? = {
            func value(_ key: String) -> String? {
                (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
            guard let apiKey = value("LastFMAPIKey"), let apiSecret = value("LastFMAPISecret") else { return nil }
            return Keys(apiKey: apiKey, apiSecret: apiSecret)
        }()
    }

    /// A connected account. The key does not expire; the user can revoke it
    /// on Last.fm, which `Failure.signedOut` then reports.
    struct Session: Codable, Sendable {
        var name: String
        var key: String
    }

    struct Play: Codable, Hashable, Sendable {
        var artist: String
        var track: String
        var album: String?
        /// Length in seconds.
        var duration: Int?
        /// When the play started, in Unix seconds.
        var timestamp: Int64
    }

    enum Failure: Error, Equatable {
        /// The account's access was revoked; it has to connect again.
        case signedOut
        case notYetAllowed
        /// Last.fm will never take the request as it is: invalid parameters,
        /// or a token that expired.
        case rejected(String)
        /// The built-in keys are unknown, suspended or mismatched. Plays
        /// wait, as for `failed`, but connecting stops.
        case invalidKeys
        /// Last.fm could not be reached or could not answer; try again later.
        case failed(String)
    }
}

extension LastFM.Play {
    /// `track` started at `start`, or nil when it lacks the artist or
    /// title Last.fm refuses a play without.
    init?(_ track: Track, at start: Date) {
        // The first artist, as Last.fm's catalogue lists features in the
        // title rather than as artists.
        artist = track.artists.first?.name ?? ""
        self.track = track.title
        album = track.album?.name
        duration = track.duration
        timestamp = Int64(start.timeIntervalSince1970)
        if artist.isEmpty || self.track.isEmpty { return nil }
    }
}

enum LastFMAPI {
    typealias Params = [(name: String, value: String)]

    private static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")
    private static let authPage = "https://www.last.fm/api/auth/"
    /// "Lily/1.0", as Lily for Windows names itself; plain "Lily" outside the app, as in ytmcheck, which has no version.
    private static let userAgent = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "Lily/\($0)" } ?? "Lily"

    /// Adds `api_sig`: the MD5 of every name and value in byte-wise name
    /// order, then the secret, as Last.fm requires of every signed call.
    static func sign(_ params: inout Params, secret: String) {
        params.sort { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        var md5 = Insecure.MD5()
        for (name, value) in params {
            md5.update(data: Data(name.utf8))
            md5.update(data: Data(value.utf8))
        }
        md5.update(data: Data(secret.utf8))
        let hex = md5.finalize().map { String(format: "%02x", $0) }.joined()
        params.append(("api_sig", hex))
    }

    /// `application/x-www-form-urlencoded`: unreserved bytes as they are,
    /// spaces as `+`, the rest escaped.
    static func form(_ params: Params) -> Data {
        var body = [UInt8]()
        for (index, (name, value)) in params.enumerated() {
            if index > 0 { body.append(UInt8(ascii: "&")) }
            escape(name, into: &body)
            body.append(UInt8(ascii: "="))
            escape(value, into: &body)
        }
        return Data(body)
    }

    private static func escape(_ string: String, into body: inout [UInt8]) {
        let hex = Array("0123456789ABCDEF".utf8)
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."),
                 UInt8(ascii: "_"), UInt8(ascii: "*"):
                body.append(byte)
            case UInt8(ascii: " "):
                body.append(UInt8(ascii: "+"))
            default:
                body += [UInt8(ascii: "%"), hex[Int(byte >> 4)], hex[Int(byte & 0xF)]]
            }
        }
    }

    /// Not through `HTTP.data`, which fails on the status alone: Last.fm's 4xx
    /// errors carry a code saying whether to retry. The host check and the
    /// guarded `HTTP.api` session still apply.
    @concurrent
    static func call(_ method: String, _ params: Params = [], keys: LastFM.Keys) async throws -> JSON {
        var params = params
        params.append(("method", method))
        params.append(("api_key", keys.apiKey))
        sign(&params, secret: keys.apiSecret)
        // Unsigned, as Last.fm leaves it out of the signature.
        params.append(("format", "json"))

        guard let endpoint, HTTP.isAllowed(endpoint) else { throw LastFM.Failure.failed("The app blocked a request to a site it doesn't use.") }
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = form(params)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await HTTP.api.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw LastFM.Failure.failed(YTMError(error).message)
        }
        let json = try? JSON(data: data)
        if let json, let code = json["error"].int {
            throw failure(code: code, message: json["message"].string ?? "", method: method)
        }
        // Something other than Last.fm answering, as a gateway's error page,
        // which would otherwise pass for a scrobble taken.
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw LastFM.Failure.failed("Last.fm answered with an error.")
        }
        guard let json else { throw LastFM.Failure.failed("Last.fm's answer couldn't be read.") }
        return json
    }

    static func failure(code: Int, message: String, method: String) -> LastFM.Failure {
        let message = "Last.fm error \(code): \(message)"
        switch code {
        // An invalid or expired token, so connecting has to start again, or
        // invalid parameters.
        case 4 where method.hasPrefix("auth."), 15 where method.hasPrefix("auth."), 6:
            return .rejected(message)
        case 9: return .signedOut
        case 14: return .notYetAllowed
        // An unknown or suspended API key, or a secret that doesn't match it.
        case 10, 13, 26: return .invalidKeys
        // Anything else, 4 on a scrobble among them, is about the account or
        // Last.fm rather than the play, so the plays wait for later.
        default: return .failed(message)
        }
    }

    /// Starts connecting an account: the page where the user allows access,
    /// and the token to ask for the session with once they have.
    static func authorise(keys: LastFM.Keys) async throws -> (page: URL, token: String) {
        let reply = try await call("auth.getToken", keys: keys)
        guard let token = reply["token"].string, var page = URLComponents(string: authPage) else {
            throw LastFM.Failure.failed("Last.fm's answer couldn't be read.")
        }
        page.queryItems = [URLQueryItem(name: "api_key", value: keys.apiKey), URLQueryItem(name: "token", value: token)]
        guard let url = page.url else { throw LastFM.Failure.failed("Last.fm's answer couldn't be read.") }
        return (url, token)
    }

    /// The session for `token`, once the user has allowed access.
    static func session(token: String, keys: LastFM.Keys) async throws -> LastFM.Session {
        let reply = try await call("auth.getSession", [("token", token)], keys: keys)
        guard let name = reply["session", "name"].string, let key = reply["session", "key"].string else {
            throw LastFM.Failure.failed("Last.fm's answer couldn't be read.")
        }
        return LastFM.Session(name: name, key: key)
    }

    static func nowPlaying(_ play: LastFM.Play, session: LastFM.Session, keys: LastFM.Keys) async throws {
        var params: Params = [("sk", session.key)]
        append(play, suffix: "", to: &params)
        _ = try await call("track.updateNowPlaying", params, keys: keys)
    }

    /// Records `plays`, at most a batch, and returns why Last.fm ignored any:
    /// those will never be taken, so they go like the others.
    static func scrobble(_ plays: [LastFM.Play], session: LastFM.Session, keys: LastFM.Keys) async throws -> [String] {
        var params: Params = [("sk", session.key)]
        for (index, play) in plays.enumerated() {
            let suffix = "[\(index)]"
            append(play, suffix: suffix, to: &params)
            params.append(("timestamp" + suffix, String(play.timestamp)))
        }
        return ignored(try await call("track.scrobble", params, keys: keys))
    }

    /// Each name followed by `suffix`, as `[0]` in a batch.
    private static func append(_ play: LastFM.Play, suffix: String, to params: inout Params) {
        params.append(("artist" + suffix, play.artist))
        params.append(("track" + suffix, play.track))
        if let album = play.album { params.append(("album" + suffix, album)) }
        if let duration = play.duration { params.append(("duration" + suffix, String(duration))) }
    }

    /// Why Last.fm ignored each play of a `track.scrobble` reply. One play
    /// comes back as an object and more as a list, with the codes as strings.
    static func ignored(_ reply: JSON) -> [String] {
        let plays = reply["scrobbles", "scrobble"]
        return (plays.isObject ? [plays] : plays.array).compactMap { play in
            let message = play["ignoredMessage"]
            guard let code = message["code"].int, code != 0 else { return nil }
            return "code \(code): \(message["#text"].string ?? "")"
        }
    }
}
