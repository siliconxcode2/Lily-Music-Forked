import Foundation
import Testing
@testable import YTMCore

/// A long playlist's later batches, as `YTMusic.loadStep` takes each one on from the step before.
@Suite struct PlaylistBatchTests {
    private func rows(_ entries: [(song: String, entry: String?)]) throws -> [JSON] {
        let rows = entries.map {
            #"{"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"\#($0.song)""#
                + ($0.entry.map { #","playlistSetVideoId":"\#($0)""# } ?? "") + "},"
                + #""flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Song \#($0.song)"}]}}}]}}"#
        }
        return try JSON(data: Data(("[" + rows.joined(separator: ",") + "]").utf8)).array
    }

    private func page(after entries: [(song: String, entry: String?)], fetched: Int? = nil) throws -> Page {
        var seen = Set<String>()
        let first = Renderers.playlistRows(try rows(entries), seen: &seen)
        return Page(
            header: PageHeader(label: "Playlist", title: "Mix"),
            sections: [.tracks(TrackSection(title: "", tracks: first.tracks, mode: .section))],
            more: .tracks(token: "t1", seen: seen, fetched: fetched ?? first.fetched)
        )
    }

    private func step(_ page: Page, _ entries: [(song: String, entry: String?)], next: String?) throws -> Page {
        guard case .tracks(_, var seen, let fetched)? = page.more else {
            Issue.record("the page had no step left")
            return page
        }
        let batch = Renderers.playlistRows(try rows(entries), seen: &seen)
        return Renderers.addingBatch((batch.tracks, batch.fetched, next), to: page, seen: seen, fetched: fetched)
    }

    @Test func dropsRepeatedEntriesButNotSongsListedTwiceCountingThem() throws {
        var seen = Set<String>()
        let first = Renderers.playlistRows(try rows([("a", "S1"), ("b", "S2"), ("c", "S3")]), seen: &seen)
        // Starting over at b, then a listed again under a new entry, and rows with no entry ID.
        let next = Renderers.playlistRows(try rows([("b", "S2"), ("c", "S3"), ("a", "S4"), ("d", nil), ("d", nil)]), seen: &seen)
        #expect(first.tracks.map(\.id) + next.tracks.map(\.id) == ["a", "b", "c", "a", "d", "d"])
        #expect(next.fetched == 5, "the repeats count towards the playlist's cap")
        #expect(next.tracks.allSatisfy { $0.setVideoId == nil }, "entry IDs only for the account's own")
        let again = Renderers.playlistRows(try rows([("a", "S1")]), entries: true, seen: &seen)
        #expect(again.tracks.isEmpty && again.fetched == 1)
    }

    @Test func carriesOnPastABatchOfRepeatsUntilOneOfNothing() throws {
        let first = try page(after: [("a", "S1"), ("b", "S2"), ("c", "S3")])
        let repeats = try step(first, [("b", "S2"), ("c", "S3")], next: "t2")
        #expect(repeats.headerTracks.map(\.id) == ["a", "b", "c"])
        #expect(repeats.more == .tracks(token: "t2", seen: ["S1", "S2", "S3"], fetched: 5))
        let fresh = try step(repeats, [("a", "S1"), ("d", "S4")], next: "t3")
        #expect(fresh.headerTracks.map(\.id) == ["a", "b", "c", "d"], "the entries seen are handed on")
        #expect(fresh.more == .tracks(token: "t3", seen: ["S1", "S2", "S3", "S4"], fetched: 7))
        #expect(fresh.header?.count == 4)
        #expect(try step(fresh, [], next: "t4").more == nil, "an empty batch ends the playlist")
    }

    @Test func stopsAtTheCapCountingRepeats() throws {
        let near = try page(after: [("a", "S1")], fetched: YTMusic.playlistLimit - 2)
        let capped = try step(near, [("a", "S1"), ("b", "S2")], next: "t2")
        #expect(capped.headerTracks.map(\.id) == ["a", "b"])
        #expect(capped.more == nil)
        let under = try step(near, [("b", "S2")], next: "t2")
        #expect(under.more == .tracks(token: "t2", seen: ["S1", "S2"], fetched: YTMusic.playlistLimit - 1))
    }
}
