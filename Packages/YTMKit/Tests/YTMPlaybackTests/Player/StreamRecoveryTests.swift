import Foundation
import Testing
@testable import YTMAudio
@testable import YTMCore
@testable import YTMPlayback

@MainActor
struct StreamRecoveryTests {
    @Test func aDroppedSongReopensWhereItFirstStopped() {
        var playback = PlaybackState()
        playback.started = true
        #expect(playback.reopenTry("a", position: 42) == 1)
        #expect(playback.playRecorded == playback.generation)
        playback.started = false
        playback.generation += 1
        #expect(playback.reopenTry("a", position: 0) == 2, "the reopen failed too")
        #expect(playback.resume?.id == "a" && playback.resume?.position == 42, "not where the stopped player is")
        #expect(playback.reopening("a"))

        #expect(playback.reopenTry("b", position: 9) == 1, "another song starts over")
        #expect(!playback.reopening("a"))
        #expect(playback.resume?.id == "a" && playback.resume?.position == 42, "b never sounded, so has no place to carry on from")
    }

    @Test func opensADroppedSongAgainWithoutASecondPlay() async throws {
        let rig = await started()
        var toasts = rig.player.toasts.makeAsyncIterator()
        rig.player.play(songs("a", "b"))
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 42
        rig.player.handle(.dropped(id: try #require(rig.playing).id))
        #expect(await toasts.next() == "Lost the connection; trying again")
        #expect(rig.player.current?.id == "a", "not skipped")
        #expect(rig.player.isPlaying && rig.player.isBuffering)
        #expect(rig.player.currentTime == 42)

        rig.player.seek(to: 50)
        rig.player.startCurrent()
        await rig.settle()
        #expect(rig.audio.played.last?.from == 50, "where it was sought to while waiting")
        await rig.soundStarts()
        #expect(await rig.lastFM.nowPlaying == ["a"], "one play")
        #expect(rig.player.playback.reopen == nil && rig.player.playback.resume == nil)
    }

    @Test func keepsTryingWhileTheReopenCantResolve() async throws {
        let rig = await started()
        var toasts = rig.player.toasts.makeAsyncIterator()
        rig.player.play(songs("a", "b"))
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 42
        rig.player.handle(.dropped(id: try #require(rig.playing).id))
        #expect(await toasts.next() == "Lost the connection; trying again")

        rig.music.set { $0.failing = ["a"] }
        rig.player.startCurrent()
        await rig.settle()
        #expect(rig.player.current?.id == "a", "still offline, so not skipped as a song that can't play")
        #expect(rig.player.playback.reopen?.tries == 2)
        #expect(rig.player.isPlaying && rig.player.isBuffering && rig.player.currentTime == 42)
    }

    @Test func aSeekOnceTheEngineHasTheSongIsNotKeptForItsRetry() async throws {
        let rig = Rig()
        rig.music.set {
            $0.signedIn = true
            $0.premium["a"] = true
        }
        await rig.player.start()
        rig.player.play(songs("a", "b"))
        await rig.settle()
        rig.player.seek(to: 50)
        #expect(rig.audio.seeks == [50] && rig.player.playback.resume == nil, "the engine has the song, so takes the seek")
        rig.player.handle(.failed(id: try #require(rig.playing).id, message: "Damaged."))
        await rig.settle()
        #expect(rig.player.stream?.isPremium == false)
        #expect(rig.audio.played.last?.from == 0, "as on Windows")
    }

    @Test func stopsOnASongThatKeepsDropping() async throws {
        let rig = await started()
        var toasts = rig.player.toasts.makeAsyncIterator()
        rig.player.play(songs("a", "b"))
        await rig.settle()
        await rig.soundStarts()
        rig.player.playback.reopen = ("a", PlayerController.maxReopens)
        rig.audio.currentTime = 42
        rig.player.handle(.dropped(id: try #require(rig.playing).id))
        #expect(await toasts.next() == "Lost the connection. Press play to carry on.")
        #expect(!rig.player.isPlaying && !rig.player.isBuffering && rig.player.current?.id == "a")
        #expect(rig.player.currentTime == 42)

        rig.player.togglePlayPause()
        await rig.settle()
        #expect(rig.audio.played.last?.from == 42, "Play carries on")
    }

    @Test func stopsQuietlyOnADropWhilePaused() async throws {
        let rig = await started()
        rig.player.play(songs("a"))
        await rig.settle()
        await rig.soundStarts()
        rig.player.togglePlayPause()
        rig.player.handle(.dropped(id: try #require(rig.playing).id))
        #expect(!rig.player.isPlaying && !rig.player.isBuffering)
        #expect(rig.player.playback.reopening("a"))
    }

    @Test func keepsTheQueuedStreamOfADroppedNextSong() async throws {
        let rig = await started()
        rig.player.play(songs("a", "b"))
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 186
        rig.player.onTick()
        await rig.settle()
        let next = try #require(rig.audio.next)
        rig.player.handle(.dropped(id: next.id))
        rig.player.handle(.finished)
        await rig.settle()
        #expect(rig.player.current?.id == "b")
        #expect(rig.music.calls.filter { $0 == "stream b" }.count == 1, "played from the stream queued")
    }

    @Test func carriesOnARefusedStreamFromAnotherClient() async throws {
        let rig = await started()
        rig.player.play(songs("a"))
        await rig.settle()
        let item = try #require(rig.playing)
        _ = try await item.refresh(false)
        _ = try await item.refresh(true)
        #expect(Array(rig.music.calls.suffix(3)) == ["stream a 251", "cut off VISIONOS", "stream a 251"], "in the same format")
    }

    @Test func stopsAfterThreeSongsInARowFailPartway() async throws {
        let rig = await started()
        rig.player.play(songs("a", "b", "c", "d"))
        try await soundThenFail(["a", "b", "c"], rig)
        #expect(rig.player.current?.id == "c", "as when googlevideo cuts every client off")
        #expect(!rig.player.isPlaying && !rig.player.isBuffering)
    }

    @Test func aSkipRestartsTheRunOfFailures() async throws {
        let rig = await started()
        rig.player.play(songs("a", "b", "c", "d", "e"))
        try await soundThenFail(["a", "b"], rig)
        rig.player.next()
        try await soundThenFail(["d"], rig)
        #expect(rig.player.current?.id == "e" && rig.player.isPlaying)
    }

    @Test func aSongPlayedThroughRestartsTheRun() async throws {
        let rig = await started()
        rig.player.play(songs("a", "b", "c", "d", "e"))
        try await soundThenFail(["a", "b"], rig)
        await rig.soundStarts()
        rig.player.handle(.finished)
        try await soundThenFail(["d"], rig)
        #expect(rig.player.current?.id == "e" && rig.player.isPlaying)
    }

    /// Each of `ids` in turn starts to sound, then fails.
    private func soundThenFail(_ ids: [String], _ rig: Rig) async throws {
        for id in ids {
            await rig.settle()
            #expect(rig.player.current?.id == id)
            await rig.soundStarts()
            rig.player.handle(.failed(id: try #require(rig.playing).id, message: "Damaged."))
        }
        await rig.settle()
    }

    /// YTMAudio can't see YTMCore, so its refresh count is checked against the clients here.
    @Test func refreshesOncePerPlainURLClient() {
        #expect(StreamLoader.maxRefreshes == ClientProfile.plainStreamClients.count)
    }
}
