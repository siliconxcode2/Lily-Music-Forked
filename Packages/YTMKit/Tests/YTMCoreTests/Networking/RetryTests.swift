import Foundation
import Synchronization
import Testing
@testable import YTMCore

/// Answers each request with the next status queued, then with 200, each with `body`.
private final class FlakyServer: URLProtocol {
    static let statuses = Mutex<[Int]>([])
    static let body = Mutex("{}")
    static let requests = Mutex(0)
    /// Each request's `X-Attempt` header.
    static let attempts = Mutex<[String?]>([])

    static func reset(_ statuses: [Int], body: String) {
        self.statuses.withLock { $0 = statuses }
        self.body.withLock { $0 = body }
        requests.withLock { $0 = 0 }
        attempts.withLock { $0 = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        Self.attempts.withLock { $0.append(request.value(forHTTPHeaderField: "X-Attempt")) }
        let status = Self.statuses.withLock { $0.isEmpty ? 200 : $0.removeFirst() }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.withLock(\.self).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct RetryTests {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlakyServer.self]
        return URLSession(configuration: config)
    }()

    private func ask(_ statuses: [Int], retries: Int, body: String = "{}", refusals: Refusals? = nil) async throws -> Int {
        FlakyServer.reset(statuses, body: body)
        let url = try #require(URL(string: "https://music.youtube.com/youtubei/v1/browse"))
        return try await HTTP.data(for: URLRequest(url: url), session: session, retries: retries, refusals: refusals).1.statusCode
    }

    @Test func signsEachAttemptAndSeesEveryAnswer() async throws {
        FlakyServer.reset([403], body: "{}")
        let url = try #require(URL(string: "https://music.youtube.com/youtubei/v1/browse"))
        var signed = 0
        var answers: [Int] = []
        let (_, response) = try await HTTP.data(
            for: URLRequest(url: url), session: session, retries: 1,
            sign: { request in
                signed += 1
                request.setValue("\(signed)", forHTTPHeaderField: "X-Attempt")
            },
            answered: { answers.append($0.statusCode) }
        )
        #expect(response.statusCode == 200 && answers == [403, 200])
        #expect(FlakyServer.attempts.withLock(\.self) == ["1", "2"])
    }

    @Test func countsAnswersAndFailsAtOnceWhenRefusedAfterAPause() async throws {
        let refusals = Refusals { $0 >= Refusals.run ? .milliseconds(300) : nil }
        for _ in 1..<Refusals.run { refusals.answered(refused: true) }
        // The run's last refusal, which pauses what follows.
        await #expect(throws: YTMError(status: 403)) { try await ask([403], retries: 0, refusals: refusals) }
        await #expect(throws: YTMError(status: 403)) { try await ask([403, 403], retries: 2, refusals: refusals) }
        #expect(FlakyServer.requests.withLock(\.self) == 1, "refused after the pause, so not retried")
    }

    @Test func asksAgainAfterAServerError() async throws {
        #expect(try await ask([503], retries: 1) == 200)
        #expect(FlakyServer.requests.withLock(\.self) == 2)
    }

    @Test func failsAtOnceOnARefusalOrWithoutRetries() async {
        await #expect(throws: YTMError(status: 404)) { try await ask([404], retries: 2) }
        #expect(FlakyServer.requests.withLock(\.self) == 1)
        await #expect(throws: YTMError(status: 503)) { try await ask([503], retries: 0) }
        #expect(FlakyServer.requests.withLock(\.self) == 1)
    }

    @Test func asksAgainAfterAStrayRefusal() async throws {
        #expect(try await ask([403], retries: 1) == 200)
        #expect(FlakyServer.requests.withLock(\.self) == 2)
    }

    @Test func failsAtOnceWhenRefusedForWantOfPermission() async {
        let denied = #"{"error":{"code":403,"message":"The caller does not have permission"}}"#
        await #expect(throws: YTMError(status: 403)) { try await ask([403], retries: 2, body: denied) }
        #expect(FlakyServer.requests.withLock(\.self) == 1)
    }

    @Test func retriesAsRustypipeDoes() {
        #expect(HTTP.isTransient(status: 429) && HTTP.isTransient(status: 500) && HTTP.isTransient(status: 503))
        #expect(!HTTP.isTransient(status: 400) && !HTTP.isTransient(status: 404) && !HTTP.isTransient(status: 403))
        #expect(HTTP.isStrayRefusal(status: 403, body: Data()) && HTTP.isStrayRefusal(status: 403, body: Data("not json".utf8)))
        #expect(HTTP.isStrayRefusal(status: 403, body: Data(#"{"error":{"message":"Request refused"}}"#.utf8)))
        let denied = Data(#"{"error":{"message":"The caller does not have permission"}}"#.utf8)
        #expect(!HTTP.isStrayRefusal(status: 403, body: denied))
        #expect(!HTTP.isStrayRefusal(status: 404, body: Data()))
        #expect(InnerTube.retries == 2)
        for _ in 0..<20 {
            #expect((Duration.seconds(1)...Duration.milliseconds(1500)).contains(HTTP.retryDelay(after: 0)))
            #expect((Duration.milliseconds(2400)...Duration.milliseconds(4500)).contains(HTTP.retryDelay(after: 1)))
            #expect(HTTP.retryDelay(after: 8) == .seconds(60), "at most a minute")
        }
    }
}
