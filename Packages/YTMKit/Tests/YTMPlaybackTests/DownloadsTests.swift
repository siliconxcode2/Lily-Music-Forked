import Foundation
import Testing
@testable import YTMCore
@testable import YTMPlayback

@MainActor
struct DownloadsTests {
    private func downloaded(_ track: Track) -> DownloadedSong {
        DownloadedSong(track: track, stream: FakeMusic.stream(track.id), added: .now)
    }

    @Test func waitForTheLaunchToSettle() async {
        let rig = Rig()
        #expect(rig.player.downloads.held, "not competing with Home")
        await rig.player.start()
        await rig.yieldToTasks()
        #expect(!rig.player.downloads.held)
    }

    @Test func removingAPlaylistKeepsTheSongsSomethingElseHolds() {
        let downloads = Rig().player.downloads
        let (a, b) = (song("a"), song("b"))
        downloads.index.singles = [a]
        downloads.index.collections = [DownloadedCollection(route: .playlist("PL"), title: "List", subtitle: "", thumbnail: nil, tracks: [a, b])]
        downloads.index.songs = ["a": downloaded(a), "b": downloaded(b)]
        #expect(!downloads.canRemove("a"), "the playlist holds it too")

        downloads.remove(.playlist("PL"))
        #expect(downloads.state(of: "a") == .downloaded)
        #expect(downloads.state(of: "b") == .none)
        #expect(downloads.state(of: .playlist("PL")) == .none)
        #expect(downloads.canRemove("a"))
    }

    @Test func aDownloadedSongPlaysItsFileWithoutAskingYouTube() async {
        let rig = await started()
        rig.player.downloads.index.singles = [song("a")]
        rig.player.downloads.index.songs = ["a": downloaded(song("a"))]
        rig.player.play(songs("a"))
        await rig.settle()
        #expect(rig.playing?.url.isFileURL == true)
        #expect(rig.playing?.cacheKey == "a-251")
        #expect(!rig.music.calls.contains { $0.hasSuffix(" a") && ($0.hasPrefix("stream") || $0.hasPrefix("premium")) })
    }

    @Test func aRemovedDownloadIsAskedForAgainNotPlayedFromItsOldFile() async {
        let rig = await started()
        let downloads = rig.player.downloads
        downloads.index.singles = [song("a")]
        downloads.index.songs = ["a": downloaded(song("a"))]
        rig.player.play(songs("a"))
        await rig.settle()
        downloads.remove(song("a"))
        rig.player.play(songs("a"))
        await rig.settle()
        #expect(rig.playing?.url.isFileURL == false)
        #expect(rig.music.calls.contains("stream a"))
    }

    @Test func smartPicksTakeFromEachListInTurnOncePerSong() {
        let picks = Downloads.interleave([songs("a", "b", "c"), songs("x", "a", "y")], count: 4)
        #expect(picks.map(\.id) == ["a", "x", "b", "c"])
    }

    @Test func aCollectionWithASongYouTubeWontSendStillFinishes() {
        let downloads = Rig().player.downloads
        let (a, b) = (song("a"), song("b"))
        downloads.index.collections = [DownloadedCollection(route: .album("MPRE"), title: "Album", subtitle: "", thumbnail: nil, tracks: [a, b])]
        downloads.index.songs = ["a": downloaded(a)]
        downloads.failed = ["b"]
        #expect(downloads.state(of: .album("MPRE")) == .downloaded)
    }

    @Test func aSongThatFailedWithARemovedPlaylistCanBeDownloadedOnItsOwn() {
        let downloads = Rig().player.downloads
        downloads.failed = ["a"]
        downloads.download(song("a"))
        #expect(downloads.index.singles.map(\.id) == ["a"])
        #expect(downloads.failed.isEmpty)
    }

    @Test func downloadsLeaveThePremiumCountersAlone() async throws {
        let music = FakeMusic()
        music.set { $0.signedIn = true }
        let chooser = StreamChooser(music: music)
        for id in ["a", "b", "c", "d"] {
            _ = try await chooser.resolve(videoId: id, wantPremium: true, signedIn: true, quality: .high, counting: false)
        }
        #expect(chooser.status == .unknown, "music videos without Premium formats don't mark the account as without it")
    }
}
