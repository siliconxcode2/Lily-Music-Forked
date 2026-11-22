import Foundation
import Testing
@testable import YTMCore
@testable import YTMPlayback

extension PlayerControllerTests {
    @Test func aQualityChangeDropsStreamsResolvedAhead() async {
        let rig = await started()
        rig.player.play(songs("a", "b"))
        await rig.settle()
        await rig.soundStarts()
        #expect(rig.player.prefetcher.has("b"))
        rig.settings.value.quality = .low
        rig.player.apply(rig.settings.value)
        #expect(!rig.player.prefetcher.has("b"), "resolved at the old quality")
    }

    @Test func aQualityChangeDropsAStreamStillResolvingAhead() async {
        let rig = await started()
        rig.music.set { $0.held = ["b"] }
        rig.player.play(songs("a", "b"))
        await rig.settle()
        await rig.soundStarts()
        rig.settings.value.quality = .low
        rig.player.apply(rig.settings.value)
        rig.music.release("b")
        await rig.settle()
        #expect(!rig.player.prefetcher.has("b"), "resolved at the old quality as it was")
        #expect(rig.audio.warmed.isEmpty)
    }

    @Test func aSkipDuringAPrefetchWaitsOnItRatherThanAskingAgain() async throws {
        let rig = await started()
        rig.music.set { $0.held = ["b"] }
        rig.player.play(songs("a", "b", "c"))
        await rig.settle()
        await rig.soundStarts()
        rig.player.next()
        await rig.yieldToTasks()
        rig.music.release("b")
        await rig.settle()
        #expect(rig.playing?.id.hasPrefix("b#") == true)
        #expect(rig.music.calls.filter { $0 == "stream b" }.count == 1)
        #expect(!rig.audio.warmed.contains { $0.id.hasPrefix("b#") }, "it plays rather than warms")
    }

    @Test func aPrefetchLandingOnceTheSongIsNoLongerNextIsNotWarmed() async throws {
        let rig = await started()
        rig.music.set { $0.held = ["b"] }
        rig.player.play(songs("a", "b", "c"))
        await rig.settle()
        await rig.soundStarts()
        rig.player.moveQueue(fromOffsets: [2], toOffset: 1)
        await rig.yieldToTasks()
        rig.music.release("b")
        await rig.settle()
        #expect(rig.audio.warmed.map { $0.id.prefix(2) } == ["c#"], "the song next now is warmed, and stays so")
        #expect(rig.player.prefetcher.has("b"), "kept for when it comes up")
    }

    @Test func aCrossfadeChangeWhileTheNextSongQueuesQueuesItAgain() async throws {
        let rig = await started()
        rig.music.set { $0.held = ["b"] }
        rig.player.play([song("a", album: "x", number: 1), song("b", album: "y", number: 1)])
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 186
        rig.player.onTick()
        rig.settings.value.crossfade = true
        rig.player.apply(rig.settings.value)
        rig.music.release("b")
        await rig.settle()
        #expect(rig.audio.next == nil, "queued with the old setting, so dropped")
        rig.player.onTick()
        await rig.settle()
        #expect(rig.audio.next?.id.hasPrefix("b#") == true)
        #expect(rig.audio.nextCrossfades)
    }
}
