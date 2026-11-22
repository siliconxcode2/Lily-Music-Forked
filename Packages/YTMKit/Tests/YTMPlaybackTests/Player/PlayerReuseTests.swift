import Foundation
import Testing
import YTMAudio
@testable import YTMCore
@testable import YTMPlayback

@MainActor
struct PlayerReuseTests {
    @Test func aPlaylistCardStartsOnItsFirstBatchAndQueuesTheRest() async {
        let rig = await started()
        rig.music.set { $0.playlistBatches["PL"] = [songs("a", "b"), songs("c", "a"), songs("d")] }
        await rig.player.play(Card(kind: .playlist, id: "PL", title: "List"))
        #expect(rig.player.current?.id == "a", "started on the first batch")
        await rig.settle()
        #expect(rig.player.queue.items.map(\.id) == ["a", "b", "c", "a", "d"], "in order, a song it holds twice too")
        #expect(!rig.music.calls.contains { $0.hasPrefix("playlist") || $0.hasPrefix("tracks") })
    }

    @Test func headerPlayOnAPartlyLoadedPlaylistStartsAtOnce() async {
        let rig = await started()
        rig.music.set { $0.playlistBatches["PL"] = [songs("a", "b"), songs("c"), songs("d")] }
        let page = Page(
            header: PageHeader(title: "List", playlistId: "PL"),
            sections: [.tracks(TrackSection(title: "", tracks: songs("a", "b"), mode: .section))],
            more: .tracks(token: "PL#1")
        )
        await rig.player.play(page)
        #expect(rig.player.current?.id == "a", "the page's tracks start at once")
        await rig.settle()
        #expect(rig.player.queue.items.map(\.id) == ["a", "b", "c", "d"])
        #expect(!rig.music.calls.contains { $0.hasPrefix("playlist") }, "nothing the page holds is asked for again")
        #expect(rig.music.calls.filter { $0.hasPrefix("more") } == ["more PL#1", "more PL#2"])

        await rig.player.play(page)
        rig.player.play(songs("x"))
        await rig.settle()
        #expect(rig.player.queue.items.map(\.id) == ["x"], "another queue drops the batches still to come")
    }

    @Test func withShuffleOnAPlaylistStartsOnItsFirstBatchToo() async {
        let rig = await started()
        rig.settings.value.shuffle = .on
        rig.player.apply(rig.settings.value)
        let all = (0..<30).map { song("\($0)") }
        rig.music.set { $0.playlistBatches["PL"] = [Array(all[..<2]), Array(all[2...])] }
        await rig.player.play(Card(kind: .playlist, id: "PL", title: "List"))
        #expect(["0", "1"].contains(rig.player.current?.id), "a card starts on a song of its first batch")
        await rig.settle()
        #expect(Set(rig.player.queue.items.map(\.id)) == Set(all.map(\.id)) && rig.player.queue.count == 30)

        let page = Page(
            header: PageHeader(title: "List", playlistId: "PL"),
            sections: [.tracks(TrackSection(title: "", tracks: Array(all[..<2]), mode: .section))],
            more: .tracks(token: "PL#1")
        )
        await rig.player.play(page)
        #expect(["0", "1"].contains(rig.player.current?.id), "and header Play's")
        await rig.settle()
        #expect(rig.player.queue.count == 30)
        #expect(!rig.music.calls.contains("playlist PL"), "the whole list is never asked for first")
    }

    @Test func headerShuffleOnAPartlyLoadedPlaylistTurnsShuffleOnAndPlaysFromThePage() async {
        let rig = await started()
        let all = (0..<12).map { song("\($0)") }
        rig.music.set { $0.playlistBatches["PL"] = [Array(all[..<6]), Array(all[6...])] }
        let page = Page(
            header: PageHeader(title: "List", shufflePlaylistId: "PLshuffle", playlistId: "PL"),
            sections: [.tracks(TrackSection(title: "", tracks: Array(all[..<6]), mode: .section))],
            more: .tracks(token: "PL#1")
        )
        await rig.player.play(page, shuffle: true)
        #expect(rig.settings.value.shuffle == .on)
        #expect(Int(rig.player.current?.id ?? "") ?? 99 < 6, "started on the page's own songs")
        await rig.settle()
        #expect(rig.player.queue.count == 12)
        #expect(!rig.music.calls.contains("playlist PLshuffle"))
    }

    @Test func aCardPlaysThePageItsLoaderGives() async {
        let rig = await started()
        let page = Page(
            header: PageHeader(title: "Album"),
            sections: [.tracks(TrackSection(title: "", tracks: songs("x", "y"), mode: .section))]
        )
        await rig.player.play(Card(kind: .album, id: "ALB", title: "Album")) { page }
        #expect(rig.player.queue.items.map(\.id) == ["x", "y"])
        #expect(!rig.music.calls.contains { $0.hasPrefix("page") || $0.hasPrefix("tracks") })

        await rig.player.startRadio(from: Card(kind: .album, id: "ALB", title: "Album")) { page }
        #expect(rig.player.queue.items.map(\.id) == ["x"], "and its radio starts from the page's first song")
        #expect(!rig.music.calls.contains { $0.hasPrefix("page") || $0.hasPrefix("tracks") })
    }

    @Test func aCardsPlaylistIsHandedOnOnlyOnceEveryBatchHasLoaded() async {
        let rig = await started()
        rig.music.set { $0.playlistBatches["PL"] = [songs("a"), songs("b"), songs("c")] }
        let handed = Handed()
        let card = Card(kind: .playlist, id: "PL", title: "List")
        await rig.player.play(card, whole: { handed.ids = $0.headerTracks.map(\.id) })
        await rig.settle()
        #expect(handed.ids == ["a", "b", "c"])

        handed.ids = nil
        rig.music.set { $0.failingBatches = ["PL#2"] }
        await rig.player.play(card, whole: { handed.ids = $0.headerTracks.map(\.id) })
        await rig.settle()
        #expect(rig.player.queue.items.map(\.id) == ["a", "b"], "what loaded plays")
        #expect(handed.ids == nil, "a playlist cut short is never taken as whole")
    }

    @Test func aSongsRadioWithShuffleOnIsShuffledIn() async {
        let rig = await started()
        rig.settings.value.shuffle = .on
        rig.player.apply(rig.settings.value)
        let radio = (1..<30).map { song("\($0)") }
        rig.music.set { $0.radios["0"] = radio }
        rig.player.startRadio(from: song("0"))
        await rig.settle()
        #expect(rig.player.queue.items.first?.id == "0", "the song plays first")
        #expect(Array(rig.player.queue.items.dropFirst().map(\.id)) != radio.map(\.id), "the radio is shuffled")
        rig.settings.value.shuffle = .off
        rig.player.apply(rig.settings.value)
        #expect(rig.player.queue.items.map(\.id) == ["0"] + radio.map(\.id), "and in its order once unshuffled")
    }

    @Test func batchesArrivingAfterShuffleIsTurnedOnKeepThePlaylistsOrder() async {
        let rig = await started()
        let all = (0..<12).map { song("\($0)") }
        rig.music.set { $0.playlistBatches["PL"] = [Array(all[..<6]), Array(all[6...])] }
        await rig.player.play(Card(kind: .playlist, id: "PL", title: "List"))
        rig.settings.value.shuffle = .on
        rig.player.apply(rig.settings.value)
        await rig.settle()
        #expect(rig.player.queue.count == 12)
        rig.settings.value.shuffle = .off
        rig.player.apply(rig.settings.value)
        #expect(rig.player.queue.items.map(\.id) == all.map(\.id), "unshuffled, the batch follows the playlist's last song")
    }

    @Test func clearingUpNextDropsAPlaylistsBatchesStillToCome() async {
        let rig = await started()
        rig.music.set { $0.playlistBatches["PL"] = [songs("a", "b"), songs("c"), songs("d")] }
        await rig.player.play(Card(kind: .playlist, id: "PL", title: "List"))
        rig.player.clearUpcoming()
        await rig.settle()
        #expect(rig.player.queue.items.map(\.id) == ["a"])
    }

    @Test func clearingUpNextDropsARadioStillLoading() async {
        let rig = await started()
        rig.music.set {
            $0.held = ["radio a"]
            $0.radios["a"] = songs("b", "c")
        }
        rig.player.startRadio(from: song("a"))
        await rig.yieldToTasks()
        rig.player.clearUpcoming()
        rig.music.release("radio a")
        await rig.settle()
        #expect(rig.player.queue.items.map(\.id) == ["a"])
        #expect(!rig.player.playback.extending, "the end of the queue may ask for a radio again")
    }

    @Test func clearingUpNextLeavesACardStillLoadingToPlay() async {
        let rig = await started()
        rig.player.play(songs("a", "b"))
        await rig.settle()
        rig.music.set {
            $0.held = ["ALB"]
            $0.playlistBatches["ALB"] = [songs("x", "y")]
        }
        let tap = Task { await rig.player.play(Card(kind: .album, id: "ALB", title: "Album")) }
        await rig.yieldToTasks()
        #expect(rig.player.pendingPlay != nil, "the album is still loading")
        rig.player.clearUpcoming()
        rig.music.release("ALB")
        await tap.value
        #expect(rig.player.current?.id == "x")
    }

    @Test func aQueueSavedAsAPlaylistAnswersItsCardForLibrary() async throws {
        let rig = await started()
        var later = song("b")
        later.thumbnail = "https://i.ytimg.com/vi/b/sddefault.jpg"
        rig.player.play([song("a"), later])
        let card = try #require(await rig.player.saveQueueAsPlaylist())
        #expect(card.kind == .playlist && card.id == "PL1" && card.title.hasPrefix("Queue "))
        #expect(card.subtitle == "Playlist • 2 songs")
        #expect(card.thumbnail == later.thumbnail, "the first queued song with artwork")
        #expect(rig.player.libraryRevision == 0, "Library keeps its copy, which the card joins")
    }

    @Test func aSkipWhileASongsRadioLoadsWaitsForIt() async {
        let rig = await started()
        rig.music.set { $0.radios["a"] = songs("b", "c") }
        rig.player.startRadio(from: song("a"))
        rig.player.next()
        await rig.settle()
        #expect(rig.player.current?.id == "b")
        #expect(rig.music.calls.filter { $0 == "radio a" }.count == 1, "asked for once")
    }

    @Test func aSkipWhileTheNextSongQueuesLeavesItsResolveRunning() async {
        let rig = await started()
        rig.music.set { $0.held = ["b"] }
        rig.player.play(songs("a", "b", "c"))
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 190
        rig.player.onTick()
        rig.player.next()
        await rig.yieldToTasks()
        rig.music.release("b")
        await rig.settle()
        #expect(rig.playing?.id.hasPrefix("b#") == true)
        #expect(rig.music.calls.filter { $0 == "stream b" }.count == 1, "the resolve ahead, not a second one")
    }

    @Test func previousPlaysTheSongBeforeFromItsKeptStream() async {
        let rig = await started()
        rig.player.play(songs("a", "b"))
        await rig.settle()
        await rig.soundStarts()
        rig.player.next()
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 1
        let warms = rig.audio.warmed.count
        rig.player.previous()
        await rig.settle()
        #expect(rig.playing?.id.hasPrefix("a#") == true)
        #expect(rig.music.calls.filter { $0 == "stream a" }.count == 1)
        await rig.soundStarts()
        #expect(rig.audio.warmed.dropFirst(warms).contains { $0.id.hasPrefix("b#") }, "the song after has its start fetched again")
        #expect(rig.music.calls.filter { $0 == "stream b" }.count == 1, "from its kept stream")
    }

    @Test func repeatOneLoopsWithoutResolvingAgain() async throws {
        let rig = await started()
        rig.settings.value.repeatMode = .one
        rig.player.apply(rig.settings.value)
        rig.player.play(songs("a"))
        await rig.settle()
        await rig.soundStarts()
        rig.audio.currentTime = 190
        rig.player.onTick()
        await rig.settle()
        let queued = try #require(rig.audio.next)
        rig.player.handle(.advanced(id: queued.id))
        await rig.settle()
        #expect(rig.music.calls.filter { $0 == "stream a" }.count == 1)
        #expect(rig.audio.warmed.isEmpty, "the file playing is not fetched again")
    }

    @Test func aWholeSongReplaysFromTheCacheHoweverOldItsStream() async throws {
        let rig = await started()
        rig.player.play(songs("a"))
        await rig.settle()
        await rig.soundStarts()
        let resolves = { rig.music.calls.filter { $0 == "stream a" }.count }
        // Two hours on, too old to resolve ahead from.
        func age() {
            rig.player.prefetcher.storePlaying(
                "a", .init(stream: FakeMusic.stream("a"), resolvedAt: .now - .seconds(2 * 60 * 60), epoch: rig.player.prefetcher.epoch)
            )
        }
        age()
        rig.audio.bufferedFraction = 1
        rig.audio.currentTime = 1
        rig.player.previous()
        await rig.settle()
        #expect(resolves() == 1, "a restart plays the whole file again")
        await rig.soundStarts()

        age()
        rig.audio.bufferedFraction = 1
        rig.settings.value.repeatMode = .one
        rig.player.apply(rig.settings.value)
        rig.audio.currentTime = 190
        rig.player.onTick()
        await rig.settle()
        _ = try #require(rig.audio.next)
        #expect(resolves() == 1, "and so does repeat one")

        rig.settings.value.repeatMode = .off
        rig.player.apply(rig.settings.value)
        age()
        rig.audio.bufferedFraction = 0.5
        rig.audio.currentTime = 1
        rig.player.previous()
        await rig.settle()
        #expect(resolves() == 2, "the rest of a part file needs a URL that works")
    }

    @Test func lyricsComeAheadAndStayForASongPlayedAgain() async {
        let rig = await started()
        let words = Lyrics(lines: ["la"])
        rig.music.set { $0.lyrics["a"] = words }
        rig.player.showsLyrics = true
        rig.player.play(songs("a", "b"))
        await rig.settle()
        await rig.player.lyricsLoad?.value
        #expect(rig.player.lyrics == .loaded(words))
        await rig.soundStarts()
        #expect(rig.music.calls.contains("lyrics b"), "the next song's, fetched ahead while shown")
        rig.player.next()
        #expect(rig.player.lyrics == .unavailable, "at once, with no loading in between")
        await rig.settle()
        rig.audio.currentTime = 1
        rig.player.previous()
        #expect(rig.player.lyrics == .loaded(words))
        #expect(rig.music.calls.filter { $0.hasPrefix("lyrics") } == ["lyrics a", "lyrics b"], "each asked for once")
    }

    @Test func lyricsThatFailedAreAskedForAgain() async {
        let rig = await started()
        rig.music.set { $0.lyricsFail = true }
        rig.player.showsLyrics = true
        rig.player.play(songs("a"))
        await rig.settle()
        await rig.player.lyricsLoad?.value
        let words = Lyrics(lines: ["la"])
        rig.music.set {
            $0.lyricsFail = false
            $0.lyrics["a"] = words
        }
        rig.player.showsLyrics = false
        rig.player.showsLyrics = true
        await rig.player.lyricsLoad?.value
        #expect(rig.player.lyrics == .loaded(words))
        #expect(rig.music.calls.filter { $0 == "lyrics a" }.count == 2, "a failure is not kept")
    }
}

/// What a card's `whole` was given, if anything.
@MainActor private final class Handed {
    var ids: [String]?
}
