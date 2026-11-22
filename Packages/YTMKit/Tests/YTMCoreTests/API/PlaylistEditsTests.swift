import Foundation
import Testing
@testable import YTMCore

@Suite struct PlaylistEditsTests {
    /// An own playlist's page of `entries`, with 500 songs more than it holds.
    private func page(_ entries: [String]) -> Page {
        let tracks = entries.map { Track(id: "video\($0)", title: $0, duration: 60) }.map { track -> Track in
            var track = track
            track.setVideoId = track.title
            return track
        }
        var header = PageHeader(title: "Mine", meta: Formatting.playlistMeta(count: entries.count + 500, tracks: tracks))
        header.count = entries.count + 500
        return Page(header: header, sections: [.tracks(TrackSection(title: "", tracks: tracks, mode: .section))])
    }

    private func order(_ page: Page) -> [String] {
        page.headerTracks.compactMap(\.setVideoId)
    }

    @Test func movesBeforeTheSongThenThere() {
        var p = page(["a", "b", "c", "d"])
        #expect(p.successor(from: 3, to: 0) == .before("a"))
        #expect(p.successor(from: 0, to: 2) == .before("d"))
        #expect(p.successor(from: 0, to: 3) == nil, "the page's end isn't the playlist's: it has 500 more")
        var whole = page(["a", "b"])
        whole.header?.count = 2
        #expect(whole.successor(from: 0, to: 1) == .end)
        if case .tracks(var section) = whole.sections[0] {
            section.tracks[0].setVideoId = nil
            whole.sections[0] = .tracks(section)
        }
        #expect(whole.successor(from: 1, to: 0) == nil, "no entry ID to go by")

        let before = p.successor(from: 3, to: 0)?.entry
        let moved = p.shiftEntry("d", before: before, at: 0)
        #expect(moved?.from == 3 && moved?.to == 0 && moved?.next == nil)
        #expect(order(p) == ["d", "a", "b", "c"])
        // Undone, it goes back to the end, where nothing followed it.
        let undone = p.shiftEntry("d", before: nil, at: 3)
        #expect(undone?.from == 0 && undone?.to == 3 && undone?.next == "a")
        #expect(order(p) == ["a", "b", "c", "d"])
        #expect(p.header?.meta.hasPrefix("504 songs") == true)
    }

    @Test func removesAndPutsBackByEntry() throws {
        var p = page(["a", "b", "c"])
        let removed = p.takeEntry("b")
        let taken = try #require(removed)
        #expect(taken.at == 1 && taken.next == "c")
        #expect(order(p) == ["a", "c"])
        #expect(p.header?.meta.hasPrefix("502 songs") == true && p.header?.count == 502)
        let again = p.takeEntry("b")
        #expect(again == nil, "already gone")

        // A song removed before it meanwhile doesn't put it out of place.
        _ = p.takeEntry("a")
        let back = p.putEntry(taken.track, before: taken.next, at: taken.at)
        #expect(back == 0)
        #expect(order(p) == ["b", "c"])
        // With what followed it gone too, it goes back where it was.
        var q = page(["a", "c"])
        _ = q.takeEntry("c")
        let there = q.putEntry(taken.track, before: "c", at: 1)
        #expect(there == 1)
        #expect(order(q) == ["a", "b"])
        // A fresh copy that still holds it isn't given it twice.
        let twice = q.putEntry(taken.track, before: nil, at: 0)
        #expect(twice == nil)
        #expect(order(q) == ["a", "b"])
    }

    /// iOS keeps a stack of pages per tab, with no Forward, so this is Windows's test for Back alone.
    @Test func forgetsADeletedPageAndTheRepeatsItLeaves() {
        let routes = { (ids: [String]) in ids.map(Route.playlist) }
        #expect(Route.forgetting(.playlist("p"), in: routes(["x", "a", "p", "a"])) == routes(["x", "a"]))
        #expect(Route.forgetting(.playlist("p"), in: routes(["x", "a", "p"])) == routes(["x", "a"]), "shown, it goes back to the page before")
        #expect(Route.forgetting(.playlist("p"), in: routes(["p", "p"])).isEmpty)
    }

    @Test func carriesTheLibraryStateOntoAnOlderCopy() {
        var live = PageHeader(title: "Revival")
        live.saved = true
        live.playlistId = "OLAK"
        var fetched = live
        fetched.saved = false
        let carried = Page(header: fetched, sections: []).keepingLibraryState(of: Page(header: live, sections: []))
        #expect(carried.header?.saved == true)

        var page = Page(header: fetched, sections: [])
        let other = page.setInLibrary(subscribe: false, id: "other", on: true)
        let subscribing = page.setInLibrary(subscribe: true, id: "OLAK", on: true)
        #expect(!other && !subscribing && page.header?.saved == false, "another album's ID, and nothing to subscribe to")
        let saving = page.setInLibrary(subscribe: false, id: "OLAK", on: true)
        #expect(saving && page.header?.saved == true)
    }
}
