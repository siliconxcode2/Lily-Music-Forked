import Foundation
import Network

/// Every URL taken from a response, and every redirect, is checked with
/// `isAllowed`, so a hostile or broken response can never send the app elsewhere.
enum HTTP {
    /// Allowed with their subdomains.
    private static let domains = [
        "youtube.com",
        "googlevideo.com",
        "ytimg.com",
        "googleusercontent.com",
        "ggpht.com",
        // Built-in artwork, such as Liked music's.
        "gstatic.com",
    ]
    /// Last.fm's API and its sign-in page, on these hosts only.
    private static let hosts: Set<String> = ["ws.audioscrobbler.com", "www.last.fm"]

    /// HTTPS on an allowed host.
    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(), !host.isEmpty else {
            return false
        }
        return hosts.contains(host) || domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// youtube.com or a subdomain: the only hosts sent or let set the account's cookies.
    static func isYouTube(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    /// Nothing is cached and no cookie is kept: the signed-in Cookie header is
    /// set per request from the Keychain.
    static let api: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        // A request that has not answered in 15 s is not going to.
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.proxyConfigurations = Proxy.configurations
        return URLSession(configuration: config, delegate: RedirectGuard.shared, delegateQueue: nil)
    }()

    /// Artwork, cached on disk across launches, within Lily for Windows's budget. Pages prefetch their cards'
    /// art and song rows load theirs as they show. Kept here, as a session's `configuration` is a copy.
    static let artworkCache = URLCache(
        memoryCapacity: 8 << 20,
        diskCapacity: 64 << 20,
        directory: URL.cachesDirectory.appending(path: "artwork", directoryHint: .isDirectory)
    )

    static let media: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = artworkCache
        // Artwork URLs name their image and size, so a stored copy is right for
        // a long while; revalidating after the short max-age only delays the
        // image. `ImagePipeline` fetches one older than 30 days again.
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 20
        config.proxyConfigurations = Proxy.configurations
        return URLSession(configuration: config, delegate: RedirectGuard.shared, delegateQueue: nil)
    }()

    /// Checks the host and fails outside 2xx; errors omit the URL, which may carry stream signatures.
    /// `retries` re-asks a 5xx, 429, stray 403 or timeout. `refusals` pauses and counts each attempt,
    /// `sign` sets its headers once its turn comes, and `answered` sees every answer.
    static func data(
        for request: URLRequest, session: URLSession = api, retries: Int = 0, refusals: Refusals? = nil,
        sign: (inout URLRequest) async -> Void = { _ in },
        answered: (HTTPURLResponse) async -> Void = { _ in }
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, isAllowed(url) else {
            throw YTMError(.refused, "The app blocked a request to a site it doesn't use.")
        }
        var attempt = 0
        while true {
            let paused = await refusals?.waitForTurn() ?? false
            var signed = request
            await sign(&signed)
            do {
                let (data, response) = try await session.data(for: signed)
                guard let http = response as? HTTPURLResponse else {
                    throw YTMError(.network, "The server's answer couldn't be read.")
                }
                await answered(http)
                let refused = isStrayRefusal(status: http.statusCode, body: data)
                refusals?.answered(refused: refused)
                if (200..<300).contains(http.statusCode) { return (data, http) }
                // Refused even after a pause: failing beats holding the caller through another.
                guard attempt < retries, refused || isTransient(status: http.statusCode), !(paused && refused) else {
                    throw YTMError(status: http.statusCode)
                }
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                guard attempt < retries, error.code == .timedOut else { throw YTMError(error) }
            }
            try await Task.sleep(for: retryDelay(after: attempt))
            attempt += 1
        }
    }

    static func isTransient(status: Int) -> Bool {
        status == 429 || (500..<600).contains(status)
    }

    /// A 403 not for want of permission, as to someone else's private playlist: YouTube refuses
    /// a share of requests so, at random and in runs, and answers the same request moments later.
    static func isStrayRefusal(status: Int, body: Data) -> Bool {
        guard status == 403 else { return false }
        let message = (try? JSON(data: body))?["error", "message"].string ?? ""
        return !message.lowercased().contains("permission")
    }

    /// 3^n seconds, jittered so callers refused together don't retry together.
    static func retryDelay(after attempt: Int) -> Duration {
        let milliseconds = pow(3, Double(attempt)) * Double.random(in: 800..<1500)
        return .milliseconds(Int(min(max(milliseconds, 1000), 60_000)))
    }
}

/// The audio engine can't import YTMCore, so the player checks each stream URL,
/// refreshed ones too, here before passing it on.
public enum HostAllowlist {
    public static func allows(_ url: URL) -> Bool { HTTP.isAllowed(url) }
}

/// Follows a redirect only to an allowed host; any other ends the request
/// with the redirect's own status, which `HTTP.data` reports as refused.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RedirectGuard()

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        request.url.map(HTTP.isAllowed) == true ? request : nil
    }
}

extension YTMError {
    init(_ error: URLError) {
        let message = switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            "You're offline."
        case .timedOut:
            "The server took too long to answer."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            "The server couldn't be reached."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            "A secure connection couldn't be made."
        default:
            "The connection failed."
        }
        self.init(.network, message)
    }

    /// A redirect only gets here when `RedirectGuard` refused to follow it.
    init(status: Int) {
        let message = switch status {
        case 300..<400: "The server sent the app to a site it doesn't use."
        case 401, 403: "The server refused the request (\(status))."
        case 404: "The server couldn't find that (404)."
        case 429: "The server is limiting requests; try again in a moment."
        case 500...: "The server had a problem (\(status))."
        default: "The request failed (\(status))."
        }
        self.init(.http, message, status: status)
    }
}
