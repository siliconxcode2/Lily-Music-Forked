import Foundation
import Network
import Synchronization

protocol ByteSource: Sendable {
    /// An upper bound of `Int64.max` asks for the rest of a file of unknown length.
    func bytes(of url: URL, headers: [String: String], range: Range<Int64>) -> AsyncThrowingStream<Data, any Error>
}

enum ByteSourceError: Error, Equatable {
    /// The server refused the URL itself, so asking again cannot help, but a fresh URL may.
    case refused
    case status(Int)
    /// The answer starts at the file's first byte, which must not follow the bytes already held.
    case notPartial
    case empty
}

final class HTTPByteSource: ByteSource {
    /// Asked for at the first request rather than when made, as reading them may touch the Keychain.
    private let proxies: @Sendable () -> [ProxyConfiguration]
    private let made = Mutex<URLSession?>(nil)

    init(proxies: @escaping @Sendable () -> [ProxyConfiguration] = { [] }) {
        self.proxies = proxies
    }

    /// The audio cache keeps the files, so nothing is cached or remembered here.
    private var session: URLSession {
        made.withLock { made in
            if let made { return made }
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 20
            configuration.proxyConfigurations = proxies()
            let session = URLSession(configuration: configuration)
            made = session
            return session
        }
    }

    func bytes(of url: URL, headers: [String: String], range: Range<Int64>) -> AsyncThrowingStream<Data, any Error> {
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let last = range.upperBound == .max ? "" : String(range.upperBound - 1)
        request.setValue("bytes=\(range.lowerBound)-\(last)", forHTTPHeaderField: "Range")
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        let task = session.dataTask(with: request)
        task.delegate = RangeDelegate(continuation: continuation, partial: range.lowerBound > 0, domain: url.host().map(Self.domain))
        continuation.onTermination = { _ in task.cancel() }
        task.resume()
        return stream
    }

    /// The host's last two labels, which a redirect may not leave.
    static func domain(of host: String) -> String {
        host.split(separator: ".").suffix(2).joined(separator: ".")
    }
}

/// Refuses statuses the download cannot use and redirects to another domain.
private final class RangeDelegate: NSObject, URLSessionDataDelegate, Sendable {
    let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    let partial: Bool
    let domain: String?

    init(continuation: AsyncThrowingStream<Data, any Error>.Continuation, partial: Bool, domain: String?) {
        self.continuation = continuation
        self.partial = partial
        self.domain = domain
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let error: ByteSourceError? = switch status {
        case 206: nil
        case 200: partial ? .notPartial : nil
        case 403: .refused
        default: .status(status)
        }
        guard let error else { return .allow }
        continuation.finish(throwing: error)
        return .cancel
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        continuation.finish(throwing: error)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, url.scheme == "https", let host = url.host(), let domain,
              host == domain || host.hasSuffix("." + domain) else { return nil }
        return request
    }
}
