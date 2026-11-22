import Foundation
import Testing
@testable import YTMCore
@testable import YTMPlayback

@MainActor
struct PlayerSettingsTests {
    @Test func theCrossfadesLengthReachesTheEngineFromLaunch() async {
        let rig = Rig()
        rig.settings.value.crossfadeSeconds = 10
        await rig.player.start()
        #expect(rig.audio.crossfadeSeconds == 10)
    }

    @Test func aNewCrossfadeLengthQueuesTheNextSongAgain() async throws {
        let rig = await started()
        rig.settings.value.crossfade = true
        rig.player.apply(rig.settings.value)
        rig.player.play([song("a", album: "x", number: 1), song("b", album: "y", number: 1)])
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 176
        rig.player.onTick()
        await rig.settle()
        #expect(rig.audio.next?.id.hasPrefix("b#") == true)

        rig.settings.value.crossfadeSeconds = 3
        rig.player.apply(rig.settings.value)
        #expect(rig.audio.crossfadeSeconds == 3)
        #expect(rig.audio.next == nil, "queued with the old length, so dropped")
        rig.audio.currentTime = 186
        rig.player.onTick()
        await rig.settle()
        #expect(rig.audio.next?.id.hasPrefix("b#") == true)
        #expect(rig.audio.nextCrossfades)
    }

    @Test func unpluggingTheDevicePlayingPauses() async throws {
        let rig = await started()
        var toasts = rig.player.toasts.makeAsyncIterator()
        rig.player.play(songs("a", "b"))
        await rig.settle()
        await rig.soundStarts()
        rig.player.outputUnplugged()
        #expect(!rig.player.isPlaying)
        #expect(rig.audio.log.last == "pause")
        #expect(rig.player.current?.id == "a", "the queue and the song stay")
        #expect(await toasts.next() == "Paused, as the device playing was unplugged")
    }

    @Test func unpluggingPlaysOnWithTheSettingOffAndLeavesAPauseAlone() async throws {
        let rig = await started()
        rig.settings.value.pauseOnUnplug = false
        rig.player.play(songs("a"))
        await rig.settle()
        await rig.soundStarts()
        rig.player.outputUnplugged()
        #expect(rig.player.isPlaying)
        #expect(!rig.audio.log.contains("pause"))
        #expect(!rig.audio.pauseOnUnplug, "nor does the engine pause itself")

        rig.settings.value.pauseOnUnplug = true
        rig.player.setPaused(true)
        rig.player.outputUnplugged()
        #expect(rig.audio.log.filter { $0 == "pause" }.count == 1, "already paused, so nothing more")
    }
}
