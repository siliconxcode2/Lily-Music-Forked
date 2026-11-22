import Foundation
import Observation
import Testing
import YTMAudio
@testable import YTMCore
@testable import YTMPlayback

@MainActor
struct PlayerControllerTests {
    @Test func playsAnAlbumGaplesslyRecordingEachPlayOnce() async throws {
        let rig = await started()
        let album = [song("a", album: "x", number: 1), song("b", album: "x", number: 2), song("c", album: "x", number: 3)]
        rig.player.play(album)
        #expect(rig.player.isBuffering && rig.player.isPlaying)
        await rig.settle()
        let first = try #require(rig.playing)
        #expect(first.id.hasPrefix("a#"))
        #expect(first.loudnessDB == -3, "turned down by YouTube's loudness")
        await rig.soundStarts()
        #expect(!rig.player.isBuffering)
        #expect(rig.history.history.tracks.map(\.id) == ["a"])
        #expect(rig.music.calls.contains("stream b"), "the next stream is resolved ahead")
        let warmed = try #require(rig.audio.warmed.last, "and its start fetched")
        #expect(warmed.id.hasPrefix("b#") && warmed.cacheKey.hasPrefix("b-"))

        rig.audio.currentTime = 170
        rig.player.onTick()
        await rig.settle()
        #expect(rig.audio.next == nil, "not yet")
        rig.audio.currentTime = 186
        rig.player.onTick()
        await rig.settle()
        let next = try #require(rig.audio.next)
        #expect(next.id.hasPrefix("b#"))
        #expect(!rig.audio.nextCrossfades, "an album in order runs straight on")
        #expect(rig.music.calls.filter { $0 == "stream b" }.count == 1, "queued from the prefetched stream")

        rig.player.handle(.advanced(id: next.id))
        await rig.settle()
        #expect(rig.player.current?.id == "b")
        #expect(rig.player.queue.currentIndex == 1)
        #expect(rig.history.history.tracks.map(\.id) == ["b", "a"])
        #expect(rig.audio.played.count == 1, "nothing loaded afresh")
        #expect(await rig.lastFM.nowPlaying == ["a", "b"])
    }

    @Test func fadesIntoSongsOfAnotherAlbumWithCrossfadeOn() async throws {
        let rig = await started()
        rig.settings.value.crossfade = true
        rig.player.play([song("a", album: "x", number: 1), song("b", album: "y", number: 1)])
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 176
        rig.player.onTick()
        await rig.settle()
        #expect(rig.audio.next?.id.hasPrefix("b#") == true, "queued earlier by the fade and the silence it may cut")
        #expect(rig.audio.nextCrossfades)
    }

    @Test func previousRestartsAfterThreeSecondsAsANewPlay() async {
        let rig = await started()
        rig.player.play(songs("a", "b"), startAt: 1)
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 10
        rig.player.previous()
        await rig.settle()
        #expect(rig.audio.seeks == [0])
        #expect(rig.player.current?.id == "b")
        #expect(await rig.lastFM.nowPlaying == ["b", "b"], "starting over is a new play")
        rig.audio.currentTime = 1
        rig.player.previous()
        await rig.settle()
        #expect(rig.player.current?.id == "a")
    }

    @Test func retriesAPremiumStreamOnTheFreeOneWithoutASecondPlay() async throws {
        let rig = Rig()
        rig.music.set {
            $0.signedIn = true
            $0.premium["a"] = true
        }
        await rig.player.start()
        rig.player.play(songs("a", "b"))
        await rig.settle()
        #expect(rig.player.stream?.isPremium == true)
        await rig.soundStarts()
        rig.audio.currentTime = 60
        rig.player.handle(.failed(id: try #require(rig.playing).id, message: "Damaged."))
        await rig.settle()
        let retry = try #require(rig.audio.played.last)
        #expect(retry.from == 60, "carries on from where the sound got to")
        #expect(rig.player.stream?.isPremium == false)
        #expect(rig.music.calls.contains("stream a"))
        await rig.soundStarts()
        #expect(await rig.lastFM.nowPlaying == ["a"], "one play")
        #expect(rig.music.calls.filter { $0 == "report a" }.count == 1)
        #expect(rig.music.calls.filter { $0 == "suspect" }.count == 1, "the player is checked sooner")
    }

    @Test func stopsAfterThreeSongsInARowFail() async {
        let rig = await started()
        rig.music.set { $0.failing = ["a", "b", "c"] }
        var toasts = rig.player.toasts.makeAsyncIterator()
        rig.player.play(songs("a", "b", "c", "d"))
        await rig.settle()
        #expect(rig.player.current?.id == "c")
        #expect(!rig.player.isPlaying && !rig.player.isBuffering)
        #expect(await toasts.next() == "Couldn't play “Song a”: No audio.")
    }

    @Test func autoplayCarriesOnWithARadioOfTheLastSong() async {
        let rig = await started()
        rig.music.set { $0.radios["a"] = songs("a", "b", "c") }
        rig.player.play(songs("a"))
        await rig.settle()
        await rig.soundStarts()
        #expect(rig.player.queue.items.map(\.id) == ["a", "b", "c"], "queued as the last song starts, once each")

        rig.player.jump(to: 2)
        await rig.settle()
        await rig.soundStarts()
        rig.music.set { $0.radios["c"] = songs("d") }
        rig.player.handle(.finished)
        await rig.settle()
        #expect(rig.player.current?.id == "d", "the queue played out moves on to a radio")
    }

    @Test func startsARadioFromASong() async {
        let rig = await started()
        rig.music.set { $0.radios["a"] = songs("b", "a", "c", "b") }
        rig.player.startRadio(from: song("a"))
        await rig.settle()
        #expect(rig.player.queue.items.map(\.id) == ["a", "b", "c"])
        #expect(rig.music.calls.filter { $0 == "radio a" }.count == 1, "autoplay doesn't ask for it again")
    }

    @Test func shuffleCyclesThroughSmartShuffleAndBack() async {
        let rig = await started()
        rig.music.set { $0.anyRadio = (0..<12).map { song("r\($0)") } }
        let own = (0..<20).map { song("\($0)") }
        rig.player.play(own)
        await rig.settle()
        rig.player.cycleShuffle()
        #expect(rig.settings.value.shuffle == .on)
        #expect(rig.player.queue.current?.id == "0" && rig.player.queue.items.map(\.id) != own.map(\.id))
        rig.player.cycleShuffle()
        await rig.settle()
        #expect(rig.settings.value.shuffle == .smart)
        #expect(!rig.player.queue.recommendedIndices.isEmpty, "recommendations mixed in")
        rig.player.cycleShuffle()
        #expect(rig.settings.value.shuffle == .off)
        #expect(rig.player.queue.items.map(\.id) == own.map(\.id), "taken out, and the order restored")
    }

    @Test func countsSeeksOnlyWithASong() async {
        let rig = await started()
        rig.player.seek(to: 10)
        #expect(rig.player.lastSeek.count == 0, "nothing to seek in")
        rig.player.play(songs("a"))
        await rig.settle()
        rig.player.seek(to: 30)
        rig.player.seek(to: 30)
        #expect(rig.player.lastSeek == Seek(count: 2, to: 30), "the same place again still counts")
        #expect(rig.audio.seeks.suffix(2) == [30, 30])
    }

    @Test func aQueueEditDropsTheQueuedSongNoLongerNext() async throws {
        let rig = await started()
        rig.player.play(songs("a", "b", "c"))
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 190
        rig.player.onTick()
        await rig.settle()
        #expect(rig.audio.next?.id.hasPrefix("b#") == true)
        rig.player.moveQueue(fromOffsets: [2], toOffset: 1)
        #expect(rig.audio.next == nil)
        rig.player.onTick()
        await rig.settle()
        #expect(rig.audio.next?.id.hasPrefix("c#") == true)
    }

    @Test func addsToTheQueueSayingSo() async {
        let rig = await started()
        var toasts = rig.player.toasts.makeAsyncIterator()
        rig.player.addToQueue(songs("a"))
        await rig.settle()
        #expect(rig.player.current?.id == "a", "an empty queue starts playing")
        rig.player.addToQueue(songs("c"))
        rig.player.playNext(songs("b1", "b2"))
        #expect(rig.player.queue.items.map(\.id) == ["a", "b1", "b2", "c"])
        #expect(await toasts.next() == "Added “Song c” to the queue")
        #expect(await toasts.next() == "2 songs play next")
    }

    @Test func ratingTogglesAndADislikeSkips() async {
        let rig = Rig()
        rig.music.set { $0.signedIn = true }
        await rig.player.start()
        rig.player.play(songs("a", "b"))
        await rig.settle()
        rig.player.rate(.like)
        #expect(rig.player.rating == .like)
        rig.player.rate(.like)
        #expect(rig.player.rating == .none, "liked again takes it back")
        rig.player.rate(.dislike)
        await rig.settle()
        #expect(rig.player.current?.id == "b")
        // Each rating is sent on its own task, so taps this close may arrive in any order.
        #expect(rig.music.calls.filter { $0.hasPrefix("rate") }.sorted() == ["rate a DISLIKE", "rate a INDIFFERENT", "rate a LIKE"])
    }

    @Test func aSmartShuffleTopUpPlacingNothingLeavesTheQueueAlone() async {
        let rig = await started()
        rig.settings.value.shuffle = .smart
        rig.player.apply(rig.settings.value)
        rig.player.play(songs("a", "b", "c", "d", "e", "f"))
        await rig.settle()
        let change = ObservedChange()
        withObservationTracking { _ = rig.player.queue } onChange: { change.mark() }
        rig.player.topUpSmartShuffle()
        #expect(!change.happened, "the pool is dry, so nothing was placed")
        await rig.settle()
    }

    @Test func aMediaServicesResetRebuildsAndCarriesOnWithoutASecondPlay() async throws {
        let rig = await started()
        rig.player.play(songs("a", "b"))
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 42
        rig.player.mediaServicesReset()
        await rig.settle()
        #expect(rig.audio.log.suffix(3).map { $0.prefix(4) } == ["rebu", "stop", "play"], "loaded once the graph is new")
        let played = try #require(rig.audio.played.last)
        #expect(played.item.id.hasPrefix("a#") && played.from == 42)
        await rig.soundStarts()
        #expect(rig.history.history.tracks.map(\.id) == ["a"])
    }

    @Test func normalisationChangesTheSongPlayingAndKeepsTheOneQueued() async throws {
        let rig = await started()
        rig.player.play([song("a", album: "x", number: 1), song("b", album: "x", number: 2)])
        await rig.settle()
        await rig.soundStarts()
        #expect(rig.audio.normalise == 1)
        rig.audio.currentTime = 186
        rig.player.onTick()
        await rig.settle()
        let queued = try #require(rig.audio.next)
        rig.settings.value.normalise = .off
        rig.player.apply(rig.settings.value)
        #expect(rig.audio.normalise == nil, "the engine applies it to what plays now")
        #expect(rig.audio.next?.id == queued.id, "the next song stays queued")
        rig.settings.value.normalise = .quiet
        rig.player.apply(rig.settings.value)
        #expect(rig.audio.normalise == 0.5, "6 dB under Normal")
    }

    @Test func headphoneSettingsReachTheAudio() async {
        let rig = await started()
        rig.settings.value.crossfeed = true
        rig.settings.value.mono = true
        rig.settings.value.balance = -0.25
        rig.player.apply(rig.settings.value)
        #expect(rig.audio.crossfeed && rig.audio.mono && rig.audio.balance == -0.25)
    }

    @Test func turnsQuietSongsUp() throws {
        var stream = FakeMusic.stream("q")
        stream.loudnessDb = -2
        let item = try PlayerController.audioItem(
            id: "q#1", videoId: "q", stream: stream, chooser: Rig().player.chooser, quality: .high, signedIn: false, local: false
        )
        #expect(item.loudnessDB == 2)
    }

    @Test func pullsTheBufferedFractionOfTheSongLoaded() async {
        let rig = await started()
        rig.audio.bufferedFraction = 0.4
        #expect(rig.player.bufferedFraction == 0, "nothing loaded")
        rig.player.play(songs("a"))
        await rig.settle()
        rig.audio.bufferedFraction = 0.4
        #expect(rig.player.bufferedFraction == 0.4)
    }

    @Test func shuffleOnAPageHeaderPlaysTheWholePlaylistShuffled() async {
        let rig = await started()
        rig.music.set { $0.radios["PLall"] = (0..<30).map { song("\($0)") } }
        let page = Page(header: PageHeader(title: "Artist", shufflePlaylistId: "PLall"), sections: [.tracks(TrackSection(title: "", tracks: songs("0", "1"), mode: .section))])
        await rig.player.play(page, shuffle: true)
        await rig.settle()
        #expect(rig.player.queue.count == 30)
        #expect(rig.settings.value.shuffle == .on, "Shuffle turns shuffle on")
    }

    @Test func loadsLyricsWhileShown() async {
        let rig = await started()
        rig.music.set { $0.lyrics["a"] = Lyrics(lines: ["la"]) }
        rig.player.play(songs("a", "b"))
        await rig.settle()
        #expect(rig.player.lyrics == .idle, "not asked for until shown")
        rig.player.showsLyrics = true
        await rig.player.lyricsLoad?.value
        #expect(rig.player.lyrics == .loaded(Lyrics(lines: ["la"])))
        rig.player.next()
        await rig.player.lyricsLoad?.value
        #expect(rig.player.lyrics == .unavailable)
    }
}

/// YTMCore can't see YTMAudio, so its bands are checked against the engine's here.
@Test func settingsKeepAGainForEveryEqualiserBand() {
    #expect(Settings.equaliserFrequencies == EqualiserBands.frequencies)
}
