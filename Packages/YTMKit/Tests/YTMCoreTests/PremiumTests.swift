import Foundation
import Testing
@testable import YTMCore

/// A miniature player shaped like YouTube's, with code the scrambler does not need.
private let testPlayer = #"""
var _yt_player={};(function(g){var window=this;
var helper = function(x) { return x.split("").reverse().join(""); };
var unused = function() { return 42; };
function Url(base) { this.params = {}; }
Url.prototype.set = function(k, v) { this.params[k] = v; };
Url.prototype.get = function(k) { return this.params[k]; };
Url.prototype.clone = function() { return this; };
Url.prototype.unscramble = function() { if (this.params.n) this.params.n = helper(this.params.n); if (this.params.s) this.params.s = encodeURIComponent(helper(decodeURIComponent(this.params.s))); };
var marker = { mark: function() {} };
g.make = function(base, key, value) { marker.mark("alr", "yes"); var u = new Url(base); if (value !== undefined) u.set(key, value); return u; };
g.other = function() { return unused(); };
init();
})(_yt_player);
"""#

private func trimmed(_ player: String) throws -> String {
    try PlayerTrimmer.trim(Array(player.utf8))
}

@Suite struct JSTokenizerTests {
    private func tokens(_ source: String) throws -> [(JSToken.Kind, String)] {
        let bytes = Array(source.utf8)
        var tokenizer = JSTokenizer(bytes)
        var out: [(JSToken.Kind, String)] = []
        while true {
            let token = try tokenizer.next()
            if token.kind == .end { return out }
            out.append((token.kind, String(decoding: bytes[token.start..<token.end], as: UTF8.self)))
        }
    }

    @Test func tellsRegularExpressionsFromDivision() throws {
        let kinds = try tokens(#"a = b / c / d; e = /x\/y[/]/g.test(f); h = (i) / 2; j = [1] / 3; return /k/"#)
            .filter { $0.0 == .regex || $0.1 == "/" }
        #expect(kinds.map(\.1) == ["/", "/", #"/x\/y[/]/g"#, "/", "/", "/k/"])
        #expect(kinds.map(\.0) == [.punctuator, .punctuator, .regex, .punctuator, .punctuator, .regex])
    }

    @Test func nestsTemplateLiterals() throws {
        let kinds = try tokens("`a${ `b${c}` + {d: 1}.d }e`").map(\.0)
        #expect(kinds == [
            .templateHead, .templateHead, .identifier, .templateTail, .punctuator,
            .punctuator, .identifier, .punctuator, .number, .punctuator, .punctuator, .identifier, .templateTail,
        ])
    }

    @Test func skipsStringsAndComments() throws {
        let words = try tokens(#"a /* } \n */ "b\"}" // c }"# + "\n'd\\'' e").map(\.1)
        #expect(words == ["a", #""b\"}""#, #"'d\''"#, "e"])
    }

    @Test func marksLineBreaks() throws {
        var tokenizer = JSTokenizer(Array("a /* \n */ b c".utf8))
        let breaks = try (0..<3).map { _ in try tokenizer.next().newlineBefore }
        #expect(breaks == [false, true, false])
    }

    @Test func rejectsUnterminatedCode() {
        for source in ["'open", "`open ${a}", "/* open", "a = /open"] {
            #expect(throws: YTMError.self) { try tokens(source) }
        }
    }
}

@Suite struct PlayerTrimmerTests {
    @Test func keepsOnlyWhatTheScramblerNeeds() throws {
        let script = try trimmed(testPlayer)
        #expect(script.contains("var helper"))
        #expect(script.contains("Url.prototype.unscramble"))
        #expect(script.contains("g.make"))
        #expect(!script.contains("var unused"), "unrelated code is dropped")
        #expect(!script.contains("g.other"), "unrelated namespace members are dropped")
        #expect(!script.contains("init()"), "top-level calls are dropped")
    }

    @Test func rejectsPlayersWithoutAScrambler() {
        let player = "var _yt_player={};(function(g){var window=this;g.a=function(){};})(_yt_player);"
        #expect(throws: YTMError.self) { try trimmed(player) }
        #expect(throws: YTMError.self) { try trimmed("not a player") }
    }

    /// A closer the tokenizer's guesses leave at the top level fails the
    /// trim rather than trapping on a statement that consumes nothing.
    @Test func rejectsAStrayCloserAtTheTopLevel() {
        for closer in [")", "]"] {
            let player = "var _yt_player={};(function(g){var window=this; \(closer) var a=1;})(_yt_player);"
            #expect(throws: YTMError.self) { try trimmed(player) }
        }
    }

    /// The player declares its names in one `var` list; naming a scrambler
    /// there must not keep everything else the list names.
    @Test func declaringANameIsNotUsingIt() throws {
        let player = """
            var _yt_player={};(function(g){var window=this;var ko,big,small;
            big=function(){return "big"};
            small=function(x){return x};
            ko=function(a){a.mark("alr","yes");return small(a)};
            })(_yt_player);
            """
        let script = try trimmed(player)
        #expect(script.contains("small=function"))
        #expect(!script.contains("big=function"))
    }

    /// Statements JavaScript ends at a line break are split there, and get
    /// their semicolon back when kept.
    @Test func splitsStatementsAtLineBreaks() throws {
        let player = """
            var _yt_player={};(function(g){var window=this
            var used=function(x){return x}
            function skipped(){}
            g.make=function(a){a.mark("alr","yes");return used(a)}
            used.extra=1
            })(_yt_player);
            """
        let script = try trimmed(player)
        #expect(script.contains("var used=function(x){return x};\n"))
        #expect(script.contains("used.extra=1;\n"))
        #expect(!script.contains("skipped"))
    }
}

@Suite struct PlayerScriptTests {
    @Test func findsPlayerVersionAndTimestamp() {
        #expect(PlayerScript.playerId(inIframeAPI: #"...trustedScriptURL("https:\/\/www.youtube.com\/s\/player\/67288f35\/www-widgetapi.vflset")"#) == "67288f35")
        #expect(PlayerScript.playerId(inIframeAPI: "nothing here") == nil)
        #expect(PlayerScript.signatureTimestamp(in: Array("x={signatureTimestamp:20744,y:1}".utf8)) == 20744)
        #expect(PlayerScript.signatureTimestamp(in: Array("a={sts:19876}".utf8)) == 19876)
    }

    @Test func checksThePlayerHourlyOrSoonerAfterAFailure() {
        let loaded = ContinuousClock.now
        var check = PlayerScripts.Check(checked: loaded)
        let fresh = check.take(at: loaded)
        #expect(!fresh, "just loaded")
        check.suspect = true
        let floor = check.take(at: loaded)
        #expect(!floor, "a failure waits out the floor")

        let first = loaded + PlayerScripts.backoff
        let sooner = check.take(at: first)
        #expect(sooner, "a failure brings it forward")
        let again = check.take(at: first)
        #expect(!again, "only one check at a time")

        let cleared = check.take(at: first + PlayerScripts.backoff)
        #expect(!cleared, "the check cleared the failure")
        let hourly = check.take(at: first + PlayerScripts.recheck)
        #expect(hourly, "due hourly regardless")
    }
}

@Suite struct SolverTests {
    @Test func solvesWithATrimmedPlayer() async throws {
        let solution = try await Solver.solve(trimmed(testPlayer), n: "abc", signature: "x/y")
        #expect(solution == Solver.Solution(n: "cba", signature: "y/x"))
    }

    @Test func stopsAPlayerThatNeverFinishes() async {
        let started = ContinuousClock.now
        await #expect(throws: YTMError.self) { try await Solver.solve("while (true) {}", n: "abc", signature: nil) }
        #expect(ContinuousClock.now - started < Solver.timeLimit * 2, "stopped at the time limit")
        await #expect(throws: YTMError.self, "stopped at the memory limit") {
            try await Solver.solve("var a = []; while (true) a.push(new Array(1e5).fill(1));", n: "abc", signature: nil)
        }
    }
}

@Suite struct PremiumResolverTests {
    private func format(_ itag: Int, _ mime: String, _ bitrate: Int, url: String? = "https://a", cipher: String? = nil) throws -> Format {
        var json: [String: Any] = ["itag": itag, "mimeType": mime, "bitrate": bitrate]
        json["url"] = url
        json["signatureCipher"] = cipher
        return try #require(Format(json: JSON(json)))
    }

    @Test func choosesPremiumFormatsFirst() throws {
        let opus = #"audio/webm; codecs="opus""#
        let free = try format(251, opus, 140_000)
        let premiumOpus = try format(774, opus, 260_000)
        let premiumAAC = try format(141, #"audio/mp4; codecs="mp4a.40.2""#, 260_000)
        func itag(_ choice: PremiumResolver.Choice) -> Int? {
            if case .play(let format) = choice { format.itag } else { nil }
        }
        let all = [free, premiumAAC, premiumOpus], no774 = [free, premiumAAC], onlyFree = [free]

        #expect(itag(PremiumResolver.choose(all, signedIn: true, anyFormat: false, maxKbps: nil)) == 774)
        #expect(itag(PremiumResolver.choose(no774, signedIn: true, anyFormat: false, maxKbps: nil)) == 141, "Premium AAC over free Opus")
        #expect(PremiumResolver.choose(onlyFree, signedIn: true, anyFormat: false, maxKbps: nil) == .notPremium)
        #expect(itag(PremiumResolver.choose(onlyFree, signedIn: true, anyFormat: true, maxKbps: nil)) == 251,
                "a known Premium account plays the free one from the same answer")
        #expect(itag(PremiumResolver.choose(all, signedIn: true, anyFormat: true, maxKbps: 192)) == 251, "a cap goes to the free formats")
        #expect(itag(PremiumResolver.choose(onlyFree, signedIn: false, anyFormat: false, maxKbps: nil)) == 251, "signed out takes what there is")
        #expect(PremiumResolver.choose([], signedIn: false, anyFormat: true, maxKbps: nil) == .noAudio)
    }

    @Test func unscramblesCipheredAndPlainURLs() async throws {
        let player = try PlayerScript(id: "test", signatureTimestamp: 1, code: trimmed(testPlayer))
        let opus = #"audio/webm; codecs="opus""#
        let ciphered = try format(774, opus, 260_000, url: nil, cipher: "s=x%2Fy%2B&sp=sig&url=https%3A%2F%2Fr1---sn-a.googlevideo.com%2Fvideoplayback%3Fitag%3D774%26n%3Dabc%26lmt%3D1")
        let url = try await PremiumResolver.unscramble(ciphered, with: player)
        #expect(url.host() == "r1---sn-a.googlevideo.com")
        #expect(url.query() == "itag=774&n=cba&lmt=1&sig=%2By%2Fx")

        let plain = try format(251, opus, 140_000, url: "https://r2---sn-b.googlevideo.com/videoplayback?n=xyz&itag=251")
        #expect(try await PremiumResolver.unscramble(plain, with: player).query() == "n=zyx&itag=251")

        let elsewhere = try format(251, opus, 140_000, url: "https://example.com/videoplayback?n=xyz")
        await #expect(throws: YTMError.self) { try await PremiumResolver.unscramble(elsewhere, with: player) }
    }

    @Test func decodesFormFields() {
        #expect(PremiumResolver.formFields("s=a%3Db+c&sp=sig&flag") == ["s": "a=b c", "sp": "sig", "flag": ""])
    }
}
