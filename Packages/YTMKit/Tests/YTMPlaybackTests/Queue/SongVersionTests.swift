import Foundation
import Testing
@testable import YTMCore
@testable import YTMPlayback

struct SongVersionTests {
    @Test func remembersLookupsAndStartsOverPastTheLimit() {
        var versions = SongVersionSwapper()
        let result16 = versions.beginLookup("v")
        #expect(result16)
        let result17 = versions.beginLookup("v")
        #expect(!result17, "under way")
        versions.found(song("s"), for: "v")
        #expect(versions.knownSong(for: "v")?.id == "s")
        for index in 0..<SongVersionSwapper.limit { _ = versions.beginLookup("p\(index)") }
        versions.found(nil, for: "p0")
        let result18 = versions.beginLookup("new")
        #expect(result18, "past the limit, the finished ones go")
        #expect(versions.knownSong(for: "v") == nil)
        let result19 = versions.beginLookup("p1")
        #expect(!result19, "pending ones stay")
    }
}
