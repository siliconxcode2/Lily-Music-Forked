import Foundation
import os

/// YouTube offers Premium formats (256 kbps) only to signed-in web clients,
/// whose URLs are scrambled by its player script.
struct PremiumResolver: Sendable {
    let innerTube: InnerTube
    let player: PlayerScript

    /// Formats only Premium accounts get: 256 kbps Opus and AAC.
    static let premiumItags = [774, 141]
    /// Web clients that skip PO tokens for Premium accounts, in order of trial.
    static let clients: [ClientProfile] = [.webRemix, .webCreator]

    enum Choice: Equatable {
        case play(Format)
        case noAudio
        /// Signed in without `anyFormat`, and no Premium format plays.
        case notPremium
    }

    /// With `anyFormat` (a known Premium account, or the last resort when no client gives plain URLs), a song
    /// without a Premium stream takes the web client's best within `maxKbps`. Signed out, it takes whatever there is.
    func resolve(videoId: String, signedIn: Bool, anyFormat: Bool, maxKbps: Int?) async throws -> PremiumOutcome {
        let clock = ContinuousClock()
        let started = clock.now
        var lastError: any Error = StreamResolver.noAudio
        for client in Self.clients {
            let response: PlayerResponse
            do {
                response = try await PlayerResponse(json: request(videoId: videoId, as: client))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Logger.premium.info("\(videoId, privacy: .public): \(client.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                lastError = error
                continue
            }
            let requested = clock.now
            let itags = response.formats.map(\.itag)
            switch Self.choose(response.formats, signedIn: signedIn, anyFormat: anyFormat, maxKbps: maxKbps) {
            case .notPremium:
                Logger.premium.info("\(videoId, privacy: .public): \(client.name, privacy: .public) has no Premium version (\(itags, privacy: .public)); playing the free stream")
                return .noPremiumFormats
            case .noAudio:
                lastError = StreamResolver.noAudio
            case .play(let format):
                let url = try await Self.unscramble(format, with: player)
                Logger.premium.info("""
                    \(videoId, privacy: .public): \(client.name, privacy: .public) itag \(format.itag) \
                    (\(format.bitrate / 1000) kbps) of \(itags, privacy: .public); request \(requested - started, privacy: .public), \
                    unscramble \(clock.now - requested, privacy: .public)
                    """)
                return .stream(makeStream(
                    format, url: url, userAgent: ClientProfile.browserUserAgent, response: response,
                    isPremium: Self.premiumItags.contains(format.itag)
                ))
            }
        }
        throw lastError
    }

    /// Quotes the player's signature timestamp so the URLs match its scrambling.
    func request(videoId: String, as client: ClientProfile) async throws -> JSON {
        // Not retried: the next client is the retry, so a broken one costs a request rather than the song.
        // Nor paused by a run of refusals or watched for a sign-out: a song never waits 40 s.
        try await innerTube.post("player", body: [
            "playbackContext": [
                "contentPlaybackContext": [
                    "html5Preference": "HTML5_PREF_WANTS",
                    "signatureTimestamp": player.signatureTimestamp,
                ],
            ],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ], client: client, retries: 0, watchesSession: false)
    }

    /// Premium formats come first, so a song with AAC 141 but no Opus 774 doesn't fall to the
    /// free Opus beside them; a bitrate cap, which they never fit, goes to the rest.
    static func choose(_ formats: [Format], signedIn: Bool, anyFormat: Bool, maxKbps: Int?) -> Choice {
        let premium = formats.filter { premiumItags.contains($0.itag) }
        if signedIn, maxKbps == nil, let format = bestAudio(premium, maxKbps: nil) { return .play(format) }
        if signedIn, !anyFormat { return .notPremium }
        return bestAudio(formats, maxKbps: maxKbps).map(Choice.play) ?? .noAudio
    }

    static func unscramble(_ format: Format, with player: PlayerScript) async throws -> URL {
        var signature: (value: String, parameter: String)?
        let address: String?
        if let url = format.url {
            address = url
        } else if let cipher = format.signatureCipher {
            let fields = formFields(cipher)
            guard let value = fields["s"] else { throw unreadable }
            address = fields["url"]
            signature = (value, fields["sp"] ?? "signature")
        } else {
            address = nil
        }
        guard let address, var parts = URLComponents(string: address) else { throw unreadable }
        var query = parts.percentEncodedQueryItems ?? []
        let n = query.firstIndex { $0.name == "n" }
        let challenge = n.flatMap { query[$0].value?.removingPercentEncoding }
        guard challenge != nil || signature != nil else { return try allowed(parts.url) }
        let solved = try await player.solve(n: challenge, signature: signature?.value)
        if let n, let value = solved.n {
            query[n].value = encoded(value)
        }
        if let signature, let value = solved.signature {
            query.append(URLQueryItem(name: encoded(signature.parameter), value: encoded(value)))
        }
        parts.percentEncodedQueryItems = query
        return try allowed(parts.url)
    }

    private static func allowed(_ url: URL?) throws -> URL {
        guard let url, HTTP.isAllowed(url) else { throw unreadable }
        return url
    }

    /// `application/x-www-form-urlencoded` pairs, decoded.
    static func formFields(_ form: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in form.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ part: Substring) -> String? {
                part.replacing("+", with: " ").removingPercentEncoding
            }
            guard let name = parts.first.flatMap(decode) else { continue }
            fields[name] = parts.count > 1 ? decode(parts[1]) : ""
        }
        return fields
    }

    /// Percent-encodes all but unreserved characters, so a value is safe anywhere in a query.
    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static let unreadable = YTMError(.unplayable, "YouTube's stream address couldn't be read.")
}
