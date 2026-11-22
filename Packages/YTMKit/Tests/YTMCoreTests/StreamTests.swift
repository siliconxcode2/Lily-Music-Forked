import Foundation
import Testing
@testable import YTMCore

/// Googlevideo URLs throughout, as the resolver only takes URLs on the allowlist.
@Suite struct StreamTests {
    private func response(_ formats: String...) throws -> JSON {
        try JSON(data: Data("""
            {"playabilityStatus":{"status":"OK"},
             "streamingData":{"adaptiveFormats":[\(formats.joined(separator: ","))]},
             "playerConfig":{"audioConfig":{"loudnessDb":-2.5}}}
            """.utf8))
    }

    private func stream(_ json: JSON, maxKbps: Int? = nil) throws -> ResolvedStream {
        try StreamResolver.stream(in: json, userAgent: "test", maxKbps: maxKbps)
    }

    private let aac = #"{"itag":140,"url":"https://r1.googlevideo.com/140?expire=1800000000","mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":137064,"contentLength":"5983881","approxDurationMs":"369626"}"#
    private let opus = #"{"itag":251,"url":"https://r1.googlevideo.com/251","mimeType":"audio/webm; codecs=\"opus\"","bitrate":146460,"contentLength":"6214234","approxDurationMs":"369641","loudnessDb":4.5}"#
    private let opusDrc = #"{"itag":251,"url":"https://r1.googlevideo.com/drc","mimeType":"audio/webm; codecs=\"opus\"","bitrate":150000,"isDrc":true}"#
    private let opusLow = #"{"itag":249,"url":"https://r1.googlevideo.com/249","mimeType":"audio/webm; codecs=\"opus\"","bitrate":52000}"#
    private let video = #"{"itag":248,"url":"https://r1.googlevideo.com/248","mimeType":"video/webm; codecs=\"vp9\"","bitrate":2000000}"#
    private let premium = #"{"itag":774,"signatureCipher":"s=abc&sp=sig&url=https%3A%2F%2Fr1.googlevideo.com%2F774","mimeType":"audio/webm; codecs=\"opus\"","bitrate":260000}"#
    private let heAAC = #"{"itag":139,"url":"https://r1.googlevideo.com/139","mimeType":"audio/mp4; codecs=\"mp4a.40.5\"","bitrate":50000}"#
    private let surround = #"{"itag":258,"url":"https://r1.googlevideo.com/258","mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":384000,"audioChannels":6}"#

    @Test func prefersOpus() throws {
        let stream = try stream(response(aac, opus, opusDrc, video))
        #expect(stream.url.absoluteString == "https://r1.googlevideo.com/251")
        #expect(stream.codec == .opus)
        #expect(stream.itag == 251)
        #expect(stream.contentLength == 6_214_234)
        #expect(stream.loudnessDb == 4.5)
        #expect(stream.duration == 369.641)
        #expect(stream.bitrate == 146_460)
        #expect(!stream.isPremium)
        #expect(stream.headers == ["User-Agent": "test"], "downloads as the same client")
    }

    @Test func capsTheBitrateForLowerQualities() throws {
        let all = try response(aac, opus, opusLow)
        #expect(try stream(all, maxKbps: AudioQuality.low.maxKbps).itag == 249)
        #expect(try stream(all, maxKbps: AudioQuality.normal.maxKbps).itag == 251)
        #expect(try stream(all, maxKbps: AudioQuality.high.maxKbps).itag == 251)
        #expect(try stream(response(aac, opus), maxKbps: 64).itag == 251, "nothing within the cap, so the lowest Opus")
    }

    @Test func skipsAACAndSurroundTheEngineRefuses() throws {
        let all = try response(heAAC, aac, surround)
        #expect(try stream(all, maxKbps: 64).itag == 140)
        #expect(try stream(all).itag == 140)
    }

    @Test func fallsBackToAAC() throws {
        let stream = try stream(response(aac, video))
        #expect(stream.itag == 140)
        #expect(stream.codec == .aac)
        #expect(stream.loudnessDb == -2.5, "uses the player-wide loudness")
    }

    @Test func capsAACToo() throws {
        let aacHigh = #"{"itag":141,"url":"https://r1.googlevideo.com/141","mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":260000}"#
        #expect(try stream(response(aac, aacHigh), maxKbps: 192).itag == 140)
        #expect(try stream(response(aac, aacHigh)).itag == 141)
    }

    @Test func skipsDubbedTracks() throws {
        let dubbed = #"{"itag":251,"url":"https://r1.googlevideo.com/dub","mimeType":"audio/webm; codecs=\"opus\"","bitrate":160000,"audioTrack":{"audioIsDefault":false}}"#
        let original = #"{"itag":250,"url":"https://r1.googlevideo.com/250","mimeType":"audio/webm; codecs=\"opus\"","bitrate":70000,"audioTrack":{"audioIsDefault":true}}"#
        #expect(try stream(response(dubbed, original)).itag == 250)
    }

    @Test func carriesOnWithTheSameFormatOnly() throws {
        let all = try response(aac, opus, opusLow)
        let pinned = { (json: JSON, itag: Int) in try StreamResolver.stream(in: json, userAgent: "test", maxKbps: nil, itag: itag) }
        #expect(try pinned(all, 249).url.absoluteString == "https://r1.googlevideo.com/249", "not the best")
        #expect(throws: StreamResolver.noAudio, "not offered") { try pinned(all, 250) }
        #expect(throws: StreamResolver.noAudio, "scrambled") { try pinned(response(premium), 774) }
        #expect(try pinned(response(opusDrc, opus), 251).url.absoluteString == "https://r1.googlevideo.com/251", "not the compressed variant")
    }

    @Test func asksCutOffClientsLastRefusedLongestAgoFirst() {
        let names = { (cut: [String]) in StreamResolver.clients(cut: cut).map(\.name) }
        #expect(names([]) == ["VISIONOS", "ANDROID_VR", "IOS"])
        #expect(names(["ANDROID_VR"]) == ["VISIONOS", "IOS", "ANDROID_VR"])

        // Only iOS works, and was refused once before: a download walking on from visionOS and Android VR still reaches it.
        var cut = ["IOS"]
        #expect(StreamResolver.mark(&cut, "VISIONOS"))
        #expect(names(cut).first == "ANDROID_VR")
        #expect(StreamResolver.mark(&cut, "ANDROID_VR"))
        #expect(names(cut) == ["IOS", "VISIONOS", "ANDROID_VR"])
        #expect(!StreamResolver.mark(&cut, "IOS"), "already marked")
        #expect(cut == ["VISIONOS", "ANDROID_VR", "IOS"], "but now refused last")
    }

    @Test func scrambledURLsCountAsNone() throws {
        #expect(throws: StreamResolver.noAudio) { try stream(response(premium)) }
    }

    @Test func picksScrambledPremiumFormats() throws {
        let response = try PlayerResponse(json: response(opus, premium))
        let best = try #require(bestAudio(response.formats, maxKbps: nil))
        #expect(best.itag == 774)
        #expect(best.signatureCipher != nil)
        #expect(best.url == nil)
    }

    @Test func reportsTheUnplayableReason() throws {
        let refused = try JSON(data: Data(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm your age"}}"#.utf8))
        #expect(throws: YTMError(.unplayable, "Sign in to confirm your age")) { try stream(refused) }
        #expect(throws: StreamResolver.noAudio) { try stream(response(video)) }
        #expect(throws: YTMError.self) { try PlayerResponse(json: JSON(data: Data("{}".utf8))) }
    }

    @Test func blocksStreamsOffTheAllowlist() throws {
        let elsewhere = #"{"itag":251,"url":"https://example.com/251","mimeType":"audio/webm; codecs=\"opus\"","bitrate":146460}"#
        #expect(throws: StreamResolver.noAudio) { try stream(response(elsewhere)) }
    }
}
