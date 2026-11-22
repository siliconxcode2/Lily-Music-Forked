import Foundation
import Testing
@testable import YTMCore
@testable import YTMPlayback

extension PlayerControllerTests {
    @Test func savesAndRestoresTheSessionPaused() async throws {
        let first = await started()
        first.player.play(songs("a", "b", "c"), startAt: 1)
        await first.settle()
        await first.soundStarts()
        first.audio.currentTime = 42
        first.player.persistSession()

        let second = await started(Rig(store: first.store))
        #expect(second.player.current?.id == "b")
        #expect(second.player.queue.count == 3)
        #expect(second.player.currentTime == 42)
        #expect(!second.player.isPlaying)
        #expect(second.audio.played.isEmpty, "nothing loads until played")
        await second.settle()
        second.player.togglePlayPause()
        await second.settle()
        let resumed = try #require(second.audio.played.last)
        #expect(resumed.item.id.hasPrefix("b#") && resumed.from == 42)
        #expect(!second.music.calls.contains("stream b"), "the last launch's stream plays without asking again")
    }

    @Test func asksAgainForAStaleOrFutureDatedSavedStream() async throws {
        var queue = Queue<Track>(seed: 1)
        queue.set(items: songs("a"), start: 0, shuffle: false)
        for resolved in [Date.now.addingTimeInterval(-2 * 60 * 60), .now.addingTimeInterval(60)] {
            let rig = Rig()
            var snapshot = try #require(SessionSnapshot(queue, position: 0, duration: 200))
            snapshot.stream = .init(stream: FakeMusic.stream("a"), resolved: resolved)
            rig.store.save(snapshot, to: .session)
            await rig.player.start()
            await rig.settle()
            #expect(rig.music.calls.contains("stream a"), "resolved ahead at launch")
        }
    }

    @Test func seeksBeforeLoadingStartThere() async throws {
        let first = await started()
        first.player.play(songs("a"))
        await first.settle()
        first.player.persistSession()
        let second = await started(Rig(store: first.store))
        second.player.seek(to: 80)
        #expect(second.player.currentTime == 80)
        #expect(second.player.lastSeek == Seek(count: 1, to: 80), "told, though nothing plays to move")
        second.player.togglePlayPause()
        await second.settle()
        #expect(try #require(second.audio.played.last).from == 80)
    }
}
