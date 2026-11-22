import Foundation
import Testing
@testable import YTMCore
@testable import YTMPlayback

struct PrefetcherTests {
    @Test func keepsStreamsForAnHour() {
        var prefetcher = StreamPrefetcher()
        let now = ContinuousClock.now
        prefetcher.store("a", .init(stream: FakeMusic.stream("a"), resolvedAt: now, epoch: prefetcher.epoch), at: now)
        #expect(prefetcher.has("a", at: now + .seconds(3599)))
        #expect(!prefetcher.has("a", at: now + .seconds(3600)), "too old to trust")
        let result13 = prefetcher.take("a", at: now + .seconds(3600))
        #expect(result13 == nil)
        #expect(!prefetcher.has("a", at: now), "taken, even when stale")
    }

    @Test func holdsThePlayingSongsStreamHoweverOldWhileItIsWhole() {
        var prefetcher = StreamPrefetcher()
        let now = ContinuousClock.now
        let later = now + .seconds(2 * 60 * 60)
        prefetcher.storePlaying("a", .init(stream: FakeMusic.stream("a"), resolvedAt: now, epoch: prefetcher.epoch), at: now)
        #expect(prefetcher.held("a") != nil)
        #expect(prefetcher.held("b") == nil)
        #expect(prefetcher.take("a", at: later) == nil, "too old to resolve ahead from")
        #expect(prefetcher.held("a") != nil, "but still replays from the cache")
        prefetcher.remove("a")
        #expect(prefetcher.held("a") == nil, "one that failed is never replayed")
        prefetcher.storePlaying("a", .init(stream: FakeMusic.stream("a"), resolvedAt: now, epoch: prefetcher.epoch), at: now)
        prefetcher.clear()
        #expect(prefetcher.held("a") == nil, "for the old quality or account")
    }

    @Test func refusesAStreamAskedForBeforeAClear() {
        var prefetcher = StreamPrefetcher()
        let asked = prefetcher.epoch
        prefetcher.clear()
        prefetcher.store("a", .init(stream: FakeMusic.stream("a"), resolvedAt: .now, epoch: asked))
        #expect(!prefetcher.has("a"), "resolved for the old quality or account")
        prefetcher.store("a", .init(stream: FakeMusic.stream("a"), resolvedAt: .now, epoch: prefetcher.epoch))
        #expect(prefetcher.has("a"))
    }

    @Test func dropsAResolveCleared() async {
        var prefetcher = StreamPrefetcher()
        let task = prefetcher.begin("a") { FakeMusic.stream("a") }
        #expect(prefetcher.isPending("a"))
        prefetcher.clear()
        #expect(!prefetcher.isPending("a"))
        let cleared = prefetcher.finish("a", task)
        #expect(!cleared, "its stream is for the old quality")
        let running = prefetcher.begin("b") { FakeMusic.stream("b") }
        let handedOn = prefetcher.takePending("b")
        #expect(handedOn == running)
        let finished = prefetcher.finish("b", running)
        #expect(!finished, "whatever took it keeps it")
    }
}
