import CryptoKit
import Foundation
import os

/// YouTube's cookies, kept in the Keychain as one `Cookie` header, and the
/// `Authorization` hashes derived from them for each request.
public actor GoogleAuth {
    public static let shared = GoogleAuth()

    private static let keychainKey = "google.cookie"
    static let log = Logger(subsystem: "Lily", category: "GoogleAuth")
    /// The cookies the Authorization hashes are made from, in the order
    /// YouTube's web client sends the schemes.
    private static let sessionCookies = ["SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID"]

    /// Read lazily, on this actor rather than whichever thread made the instance.
    private lazy var cookie: String? = Keychain.data(for: Self.keychainKey).map { String(decoding: $0, as: UTF8.self) }

    /// Yields when YouTube answers a signed-in request as signed out, as it does once the session
    /// has ended. Answers arriving while nothing waits wake the next wait. One reader, the app.
    public nonisolated let signInLost: AsyncStream<Void>
    private nonisolated let lost: AsyncStream<Void>.Continuation

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        signInLost = stream
        lost = continuation
    }

    public var isSignedIn: Bool { cookie != nil }

    /// The stored `Cookie` header, kept current by the cookies signed-in answers set.
    var sessionCookie: String? { cookie }

    /// Keeps the session cookies of .youtube.com / .google.com read from the sign-in web view.
    public func signIn(cookies: [HTTPCookie]) throws {
        guard let header = Self.cookieHeader(cookies) else {
            throw YTMError(.notSignedIn, "Signing in didn't finish: Google gave no session. Try again.")
        }
        cookie = header
        Keychain.set(Data(header.utf8), for: Self.keychainKey)
    }

    public func signOut() {
        cookie = nil
        Keychain.set(nil, for: Self.keychainKey)
    }

    /// What a signed-in request to `origin` carries; nil when signed out.
    func headers(origin: String) -> [String: String]? {
        guard let cookie else { return nil }
        var headers = ["Cookie": cookie, "X-Goog-AuthUser": "0", "X-Origin": origin, "Origin": origin]
        headers["Authorization"] = Self.authorization(cookie: cookie, origin: origin, time: Int(Date.now.timeIntervalSince1970))
        return headers
    }

    /// Takes in the `Set-Cookie`s of an answer to a request that sent `sent`, as a browser does,
    /// so the stored session keeps up with Google rotating it. Answers for another login, or from off
    /// youtube.com after a redirect, are left out.
    func take(_ response: HTTPURLResponse, sent: String) {
        guard let setCookie = response.value(forHTTPHeaderField: "Set-Cookie"), let url = response.url, HTTP.isYouTube(url.host()),
              let stored = cookie, let login = Self.login(sent), Self.login(stored) == login
        else { return }
        // Foundation splits the joined header, whose Expires dates hold commas too.
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": setCookie], for: url)
        guard let merged = Self.merge(stored, setting: cookies, now: .now) else { return }
        cookie = merged
        Keychain.set(Data(merged.utf8), for: Self.keychainKey)
    }

    /// Called when a signed-in request is answered as signed out.
    nonisolated func lostSignIn() {
        Self.log.warning("YouTube answered a signed-in request as signed out")
        lost.yield()
    }

    /// Unexpired youtube.com and google.com cookies, each name once with
    /// YouTube's first; nil without a session cookie to sign requests with.
    static func cookieHeader(_ cookies: [HTTPCookie]) -> String? {
        let now = Date.now
        func domain(_ cookie: HTTPCookie) -> String? {
            let host = cookie.domain.lowercased().trimmingPrefix(".")
            return ["youtube.com", "google.com"].first { host == $0 || host.hasSuffix("." + $0) }
        }
        let kept = cookies
            .filter { cookie in cookie.expiresDate.map { $0 > now } ?? true }
            .compactMap { cookie in domain(cookie).map { (cookie, $0) } }
            .sorted { $0.1 == "youtube.com" && $1.1 != "youtube.com" }
        var names = Set<String>()
        let pairs = kept.compactMap { cookie, _ in
            names.insert(cookie.name).inserted ? "\(cookie.name)=\(cookie.value)" : nil
        }
        guard !names.isDisjoint(with: sessionCookies) else { return nil }
        return pairs.joined(separator: "; ")
    }

    /// `cookie` with the youtube.com-wide ones of `cookies` put in by name, or nil when that
    /// changes nothing. Deletions are left out, so a session is only ever ended by signing out.
    static func merge(_ cookie: String, setting cookies: [HTTPCookie], now: Date) -> String? {
        var jar = pairs(cookie).map { (name: String($0.name), value: String($0.value)) }
        var changed = false
        for new in cookies {
            // Host-only cookies carry the full host, such as music.youtube.com.
            let domainWide = new.domain.lowercased().trimmingPrefix(".") == "youtube.com"
            let deleted = new.value.isEmpty || new.expiresDate.map { $0 <= now } == true
            guard domainWide, !deleted, !new.name.isEmpty else { continue }
            if let index = jar.firstIndex(where: { $0.name == new.name }) {
                guard jar[index].value != new.value else { continue }
                jar[index].value = new.value
            } else {
                jar.append((new.name, new.value))
            }
            changed = true
        }
        return changed ? jar.map { "\($0.name)=\($0.value)" }.joined(separator: "; ") : nil
    }

    /// What tells apart the logins `Cookie` headers are for.
    static func login(_ cookie: String) -> Substring? {
        value("SAPISID", in: cookie) ?? value("__Secure-3PAPISID", in: cookie)
    }

    private static func value(_ name: String, in cookie: String) -> Substring? {
        pairs(cookie).first { $0.name == name }?.value
    }

    /// The `name=value` pairs of a `Cookie` header.
    private static func pairs(_ cookie: String) -> [(name: Substring, value: Substring)] {
        cookie.split(separator: ";").compactMap { pair in
            let pair = pair.trimmingPrefix(" ")
            guard let eq = pair.firstIndex(of: "=") else { return nil }
            return (pair[..<eq], pair[pair.index(after: eq)...])
        }
    }

    /// Per session cookie, `SCHEME <time>_<sha1("<time> <cookie> <origin>")>`,
    /// space-separated; SAPISIDHASH falls back to the 3P cookie.
    static func authorization(cookie: String, origin: String, time: Int) -> String? {
        let schemes: [(String, Substring?)] = [
            ("SAPISIDHASH", login(cookie)),
            ("SAPISID1PHASH", value("__Secure-1PAPISID", in: cookie)),
            ("SAPISID3PHASH", value("__Secure-3PAPISID", in: cookie)),
        ]
        let parts = schemes.compactMap { scheme, id -> String? in
            guard let id else { return nil }
            let digest = Insecure.SHA1.hash(data: Data("\(time) \(id) \(origin)".utf8))
            return "\(scheme) \(time)_\(digest.map { String(format: "%02x", $0) }.joined())"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
