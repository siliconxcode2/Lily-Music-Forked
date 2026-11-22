import Foundation
import Testing
@testable import YTMCore

@Suite struct LyricsTests {
    private func timed(_ lines: String) throws -> JSON {
        try JSON(data: Data(#"""
            {"contents":{"elementRenderer":{"newElement":{"type":{"componentType":{"model":{"timedLyricsModel":{"lyricsData":{
              "timedLyricsData":[\#(lines)],"sourceMessage":"Source: Musixmatch"}}}}}}}},"frameworkUpdates":{"big":[1,2,3]}}
            """#.utf8))
    }

    @Test func readsSyncedLinesWithTheirStarts() throws {
        let json = try timed(#"""
            {"lyricLine":"One","cueRange":{"startTimeMilliseconds":"1500","endTimeMilliseconds":"3000","metadata":{"id":"1"}}},
            {"lyricLine":"Two","cueRange":{"startTimeMilliseconds":"3000","endTimeMilliseconds":"4000"}}
            """#)
        #expect(Lyrics(timed: json) == Lyrics(lines: ["One", "Two"], starts: [1.5, 3.0], source: "Source: Musixmatch"))
    }

    @Test func untimedLinesHaveNoStarts() throws {
        let lyrics = try #require(Lyrics(timed: timed(#"{"lyricLine":"One"},{"lyricLine":"Two","cueRange":{"startTimeMilliseconds":"3000"}}"#)))
        #expect(lyrics.lines == ["One", "Two"])
        #expect(lyrics.starts.isEmpty, "synced only when every line is")
    }

    @Test func otherShapesAreNone() throws {
        #expect(Lyrics(timed: try timed("")) == nil, "no lines")
        #expect(Lyrics(timed: try JSON(data: Data(#"{"contents":{"sectionListRenderer":{}}}"#.utf8))) == nil)
    }

    @Test func readsPlainLyrics() throws {
        let json = try JSON(data: Data(#"""
            {"contents":{"sectionListRenderer":{"contents":[{"musicDescriptionShelfRenderer":{
              "description":{"runs":[{"text":"One\r\nTwo\n\nThree\n"}]},"footer":{"runs":[{"text":"Source: LyricFind"}]}}}]}}}
            """#.utf8))
        let lyrics = try #require(try Lyrics(plain: json))
        #expect(lyrics == Lyrics(lines: ["One", "Two", "", "Three"], source: "Source: LyricFind"))
        #expect(!lyrics.isSynced)
    }

    @Test func aMessageIsNoLyrics() throws {
        let message = try JSON(data: Data(#"{"contents":{"messageRenderer":{"text":{"runs":[{"text":"Lyrics not available"}]}}}}"#.utf8))
        #expect(try Lyrics(plain: message) == nil)
        #expect(throws: YTMError.self) { try Lyrics(plain: JSON(data: Data(#"{"contents":{"sectionListRenderer":{"contents":[]}}}"#.utf8))) }
    }

    @Test func splitsLinesAsRust() {
        #expect(Lyrics.lines("") == [])
        #expect(Lyrics.lines("a") == ["a"])
        #expect(Lyrics.lines("a\n\n") == ["a", ""])
        #expect(Lyrics.lines("a\r\nb") == ["a", "b"])
    }
}
