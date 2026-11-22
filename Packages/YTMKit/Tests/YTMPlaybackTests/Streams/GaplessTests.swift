import Foundation
import Testing
@testable import YTMCore
@testable import YTMPlayback

struct GaplessTests {
    private func track(_ album: String?, _ number: Int?) -> Track {
        Track(id: "x", title: "x", album: album.map { AlbumRef(id: $0, name: "Album") }, trackNumber: number)
    }

    @Test func runsAnAlbumOnWithoutFading() {
        let first = track("a", 1)
        #expect(GaplessScheduler.inAlbumOrder(first, track("a", 2)))
        #expect(GaplessScheduler.inAlbumOrder(first, track("a", nil)), "numbers unknown, assumed in order")
    }

    @Test func fadesBetweenAnythingElse() {
        let first = track("a", 1)
        #expect(!GaplessScheduler.inAlbumOrder(first, track("a", 5)), "shuffled")
        #expect(!GaplessScheduler.inAlbumOrder(first, track("b", 2)))
        #expect(!GaplessScheduler.inAlbumOrder(track(nil, nil), track(nil, nil)))
        #expect(!GaplessScheduler.inAlbumOrder(nil, first))
        #expect(!GaplessScheduler.inAlbumOrder(track("a", .max), track("a", 0)))
    }

    @Test func queuesEarlierByTheFadeAndTheSilenceItMayCut() {
        #expect(GaplessScheduler.lead(crossfade: 0, speed: 1) == 15)
        #expect(GaplessScheduler.lead(crossfade: 6, speed: 1) == 25)
        #expect(GaplessScheduler.lead(crossfade: 12, speed: 1) == 31, "the longest fade offered")
        #expect(abs(GaplessScheduler.lead(crossfade: 6, speed: 1.2) - 28) < 1e-9, "only opening the next takes clock time")
    }

    @Test func queuesTheNextSongOnceNearTheEnd() {
        var scheduler = GaplessScheduler()
        let (a, b) = (song("a"), song("b"))
        func plan(at position: Double) -> (stale: Bool, due: (id: String, crossfade: Double)?) {
            scheduler.plan(position: position, duration: 200, started: true, current: a, next: b, crossfadeSeconds: 6, speed: 1)
        }
        #expect(plan(at: 170).due == nil, "too early, even with a fade")
        #expect(plan(at: 176).due?.id == "b")
        #expect(plan(at: 176).due?.crossfade == 6, "songs of different albums fade")
        scheduler.markTried("b")
        #expect(plan(at: 190).due == nil, "a failed attempt is not retried every tick")
    }
}
