import Foundation

final class InnerTube: Sendable {
    let auth: GoogleAuth
    private let visitor: VisitorData
    private let refusals = Refusals()

    /// English, so parsers can read YouTube's labels ("Song", "1.2M"); the
    /// country picks charts and catalogue.
    static let language = "en"
    static let country = "US"

    static let retries = 2

    /// The consent cookie a browser that dismissed YouTube's banner sends,
    /// so signed-out web requests from Europe get pages, not the banner.
    static let consentCookie = "SOCS=CAISAiAD"

    init(auth: GoogleAuth, store: FileStore) {
        self.auth = auth
        visitor = VisitorData(store: store, request: VisitorData.request)
    }

    /// Keys `body` gives in `context.client` override the client's own.
    /// `authenticated` only affects web clients; `visitorData` tries an ID
    /// before keeping it. Requests with a fallback of their own pass `retries: 0`. With `watchesSession`,
    /// signed-in requests wait out refusal pauses, take in Set-Cookies and notice a lost session.
    @concurrent
    func post(
        _ endpoint: String, body: [String: Any] = [:], client: ClientProfile = .webRemix,
        authenticated: Bool = true, visitorData: String? = nil, retries: Int = InnerTube.retries,
        watchesSession: Bool = true
    ) async throws -> JSON {
        guard let url = client.url(endpoint) else {
            throw YTMError(.parse, "The request couldn't be made.")
        }
        let visitorData = if let visitorData { visitorData } else { try await visitor.value() }
        var body = body
        var context = body["context"] as? [String: Any] ?? [:]
        context["client"] = client.context(hl: Self.language, gl: Self.country, visitorData: visitorData)
            .merging(context["client"] as? [String: Any] ?? [:]) { $1 }
        body["context"] = context
        guard JSONSerialization.isValidJSONObject(body) else {
            throw YTMError(.parse, "The request couldn't be made.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let headers = client.headers(visitorData: visitorData)
        request.allHTTPHeaderFields = headers
        let watched = watchesSession && client.isWeb && authenticated && client.origin != nil
        let counted = watched ? await auth.isSignedIn : false
        // The account's cookie the latest attempt sent: only those answers are taken in.
        var sent: String?
        let (data, _) = try await HTTP.data(
            for: request, retries: retries, refusals: counted ? refusals : nil,
            // Signed per attempt: the hash carries the time, and a pause may see the cookie renewed or removed.
            sign: { request in
                sent = nil
                guard client.isWeb else { return }
                if authenticated, let origin = client.origin, let account = await auth.headers(origin: origin) {
                    request.allHTTPHeaderFields = headers.merging(account) { $1 }
                    sent = account["Cookie"]
                } else {
                    request.setValue(Self.consentCookie, forHTTPHeaderField: "Cookie")
                }
            },
            // Whatever the status, as a browser takes them in.
            answered: { response in
                if watched, let sent { await auth.take(response, sent: sent) }
            }
        )
        let json = try JSON(data: data)
        if watched, sent != nil, Renderers.answeredSignedOut(json) { auth.lostSignIn() }
        return json
    }

    func browse(_ browseId: String, params: String? = nil, authenticated: Bool = true) async throws -> JSON {
        var body: [String: Any] = ["browseId": browseId]
        if let params { body["params"] = params }
        return try await post("browse", body: body, authenticated: authenticated)
    }

    func continuation(_ token: String, authenticated: Bool = true) async throws -> JSON {
        try await post("browse", body: ["continuation": token], authenticated: authenticated)
    }

    func visitorData() async throws -> String {
        try await visitor.value()
    }

    /// A visitor ID to try in place of `refused`, not kept yet. Callers asking
    /// together share one fetch.
    func candidateVisitorData(replacing refused: String) async throws -> String {
        try await visitor.candidate(replacing: refused)
    }

    /// Keeps `candidate`, which worked where `refused` failed.
    func adoptVisitorData(_ candidate: String, replacing refused: String) async {
        await visitor.adopt(candidate, replacing: refused)
    }

    func forgetVisitorData() async {
        await visitor.forget()
    }
}

/// Saved so a launch needs no fetch, and replaced in the background once a day
/// old. A fresh ID only replaces the saved one once it has worked where the
/// saved one failed: both failing points at the song, not the ID.
actor VisitorData {
    private struct Saved: Codable, Sendable {
        let value: String
        let fetched: Date
    }

    private static let maxAge: TimeInterval = 24 * 60 * 60
    private let store: FileStore
    private let request: @Sendable () async throws -> String
    /// Checked, as it goes into a header.
    private lazy var saved: Saved? = store.load(Saved.self, from: .visitor).flatMap { Self.isUsable($0.value) ? $0 : nil }
    /// The fetch in flight, which every caller arriving meanwhile awaits.
    private var fetching: Task<String, any Error>?
    /// Bumped by `forget`.
    private var generation = 0

    init(store: FileStore, request: @escaping @Sendable () async throws -> String) {
        self.store = store
        self.request = request
    }

    /// A day-old saved ID is still sent while a new one is fetched behind it,
    /// so no request waits on the refresh.
    func value() async throws -> String {
        guard let saved else { return try await fetchAndKeep() }
        if !Self.isFresh(saved), fetching == nil {
            Task { try? await refresh() }
        }
        return saved.value
    }

    /// Replaces a day-old ID; a failed fetch leaves it in use.
    private func refresh() async throws {
        // Requests arriving before the first refresh starts each queue one;
        // those behind a finished refresh have nothing to do.
        guard saved.map(Self.isFresh) != true else { return }
        _ = try await fetchAndKeep()
    }

    /// Callers sharing a fetch keep it once; none keeps one `forget` overtook.
    private func fetchAndKeep() async throws -> String {
        let generation = generation
        let value = try await fetch()
        if generation == self.generation, saved.map(Self.isFresh) != true { keep(value) }
        return value
    }

    /// An ID to try in place of `refused`: the saved one if another caller
    /// has replaced it already, else a new one, not kept.
    func candidate(replacing refused: String) async throws -> String {
        if let saved, saved.value != refused { return saved.value }
        return try await fetch()
    }

    /// Keeps `candidate` in place of `refused`, unless another caller has
    /// replaced it already or `forget` dropped it.
    func adopt(_ candidate: String, replacing refused: String) {
        guard saved?.value == refused else { return }
        keep(candidate)
    }

    /// The ID belongs to the account it was sent with; the next request fetches another.
    func forget() {
        generation += 1
        saved = nil
        fetching = nil
        store.remove(.visitor)
    }

    private func fetch() async throws -> String {
        if let fetching { return try await fetching.value }
        let request = request
        let task = Task { try await request() }
        fetching = task
        // Unless `forget` let another start meanwhile.
        defer { if fetching == task { fetching = nil } }
        return try await task.value
    }

    private func keep(_ value: String) {
        let saved = Saved(value: value, fetched: .now)
        self.saved = saved
        store.save(saved, to: .visitor)
    }

    private static func isFresh(_ saved: Saved) -> Bool {
        -saved.fetched.timeIntervalSinceNow < maxAge
    }

    /// Falls back to the home page when the endpoint answers in another shape.
    /// A refusal fails at once: the page, on the same host, would be refused too.
    static func request() async throws -> String {
        let client = ClientProfile.webRemix
        guard let url = client.url("visitor_id"), let home = URL(string: "https://music.youtube.com/") else {
            throw YTMError(.parse, "The request couldn't be made.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": ["clientName": client.name, "clientVersion": client.version]],
        ])
        request.allHTTPHeaderFields = client.headers(visitorData: nil).merging(["Cookie": InnerTube.consentCookie]) { $1 }
        let (data, _) = try await HTTP.data(for: request)
        if let value = try? JSON(data: data)["responseContext", "visitorData"].string, isUsable(value) {
            return value
        }

        var page = URLRequest(url: home)
        page.allHTTPHeaderFields = ["User-Agent": client.userAgent, "Cookie": InnerTube.consentCookie]
        let (html, _) = try await HTTP.data(for: page)
        guard let value = visitorData(inPage: String(decoding: html, as: UTF8.self)) else {
            throw YTMError(.parse, "YouTube didn't give the app a visitor ID.")
        }
        return value
    }

    /// The first `"visitorData":"…"` in YouTube's page.
    static func visitorData(inPage html: String) -> String? {
        let marker = #""visitorData":""#
        guard let start = html.range(of: marker)?.upperBound,
              let end = html[start...].firstIndex(of: "\"")
        else { return nil }
        let value = String(html[start..<end])
        return isUsable(value) ? value : nil
    }

    /// Sent as a header with every request, so it must be one: base64url
    /// and percent escapes only.
    private static func isUsable(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-%=".contains($0)) }
    }
}
