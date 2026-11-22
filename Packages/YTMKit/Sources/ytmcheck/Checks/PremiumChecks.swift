import Foundation
@testable import YTMCore

/// Signed out there are no Premium formats, but the scrambling is the same,
/// so this is what breaks when YouTube changes it.
enum PremiumChecks {
    static func run(_ report: Report) async {
        var player: PlayerScript?
        await report.check("premium player trims and solves") { findings in
            let clock = ContinuousClock()
            let started = clock.now
            let script = try await PlayerScript.load(store: Live.store)
            let loaded = clock.now - started
            player = script
            findings.expect(script.id.count == 8 && script.id.allSatisfy(\.isHexDigit), "player ID \(script.id)")
            findings.expect(script.signatureTimestamp > 20_000, "signature timestamp \(script.signatureTimestamp)")
            let solved = try await script.solve(n: PlayerScript.checkN, signature: PlayerScript.checkSignature)
            let again = try await script.solve(n: PlayerScript.checkN, signature: PlayerScript.checkSignature)
            findings.expect(solved == again, "solving twice gave two answers")
            let cached = try await PlayerScript.load(store: Live.store)
            findings.expect(cached.code == script.code, "the saved player isn't the one trimmed")
            findings.note("player \(script.id), sts \(script.signatureTimestamp), trimmed to \(script.code.utf8.count >> 10) KB; loaded in \(loaded.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))")
        }

        await report.check("premium WEB_REMIX signatureCipher") { findings in
            guard let player else { return findings.fail("no player to solve with") }
            let resolver = PremiumResolver(innerTube: Live.api.innerTube, player: player)
            for song in Live.songs.prefix(2) {
                let response = try PlayerResponse(json: await resolver.request(videoId: song.id, as: .webRemix))
                let ciphered = response.formats.filter { $0.signatureCipher != nil }
                guard let format = bestAudio(ciphered, maxKbps: nil) else {
                    findings.fail("\(song.title): no signatureCipher audio among itags \(response.formats.map(\.itag)), \(response.formats.filter { $0.url != nil }.count) plain")
                    continue
                }
                let url = try await PremiumResolver.unscramble(format, with: player)
                let stream = makeStream(format, url: url, userAgent: ClientProfile.browserUserAgent, response: response, isPremium: false)
                findings.audit(stream, song.title, seconds: song.seconds, maxKbps: nil)
                findings.note("\(song.title): \(ciphered.count) scrambled formats; " + (try await findings.probe(stream, song.title)))
            }
        }

        await report.check("premiumStream signed out") { findings in
            let song = Live.songs[0]
            guard case .stream(let stream) = try await Live.api.premiumStream(videoId: song.id, anyFormat: true) else {
                return findings.fail("signed out, the web client's best wasn't taken")
            }
            findings.expect(!stream.isPremium, "a Premium format signed out")
            findings.audit(stream, song.title, seconds: song.seconds, maxKbps: nil)
            findings.note(try await findings.probe(stream, song.title))
            guard case .stream(let capped) = try await Live.api.premiumStream(videoId: song.id, anyFormat: true, maxKbps: 64) else {
                return findings.fail("no stream within 64 kbps")
            }
            findings.audit(capped, "64 kbps", seconds: song.seconds, maxKbps: 64)
        }
    }
}
