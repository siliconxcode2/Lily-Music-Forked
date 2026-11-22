import Foundation
import Testing
@testable import YTMCore
@testable import YTMPlayback

@MainActor
struct WatchReportTests {
    private let start = ContinuousClock.now

    private func ping() throws -> WatchTime {
        WatchTime(url: try #require(URL(string: "https://s.youtube.com/api/stats/watchtime")), scheduled: [10, 20, 30], every: 40, login: nil)
    }

    private func at(_ seconds: Double) -> ContinuousClock.Instant {
        start + .milliseconds(Int(seconds * 1000))
    }

    @Test func joinsStretchesPlayedOnAndSplitsThemAtASeek() {
        var report = WatchReport(started: start)
        for (position, time) in [(0.0, 0.0), (0.25, 0.25), (0.5, 0.5), (60, 0.75), (60.25, 1)] {
            report.tick(position: position, speed: 1, at: at(time))
        }
        #expect(report.stretches == [0...0.5, 60...60.25])
    }

    @Test func aSeekWhilePausedIsNotHeard() {
        var report = WatchReport(started: start)
        report.tick(position: 0, speed: 1, at: at(0))
        report.tick(position: 0.25, speed: 1, at: at(0.25))
        report.seeked()
        report.tick(position: 30.25, speed: 1, at: at(60))
        report.tick(position: 30.5, speed: 1, at: at(60.25))
        #expect(report.stretches == [0...0.25, 30.25...30.5], "30 s sought to over a minute paused")
    }

    @Test func pingsOnTheScheduleOnPausingAndAsThePlayEnds() throws {
        var report = WatchReport(started: start)
        report.tick(position: 0, speed: 1, at: at(0))
        report.tick(position: 0.25, speed: 1, at: at(0.25))
        let unknown = report.flush(.now, paused: true, at: at(1))
        #expect(unknown == nil && report.stretches == [0...0.25], "kept until the play's report says where")

        report.answered(try ping())
        let early = report.flush(.due, paused: false, at: at(5))
        #expect(early == nil)
        let duePing = report.flush(.due, paused: false, at: at(10))
        let due = try #require(duePing)
        #expect(due.watched.stretches == [0...0.25] && due.watched.elapsed == .seconds(10) && !due.watched.last)
        let nothingNew = report.flush(.now, paused: true, at: at(12))
        #expect(nothingNew == nil, "nothing heard since")

        report.tick(position: 0.5, speed: 1, at: at(0.5))
        let pausedPing = report.flush(.now, paused: true, at: at(15))
        let paused = try #require(pausedPing)
        #expect(paused.watched.paused && paused.watched.stretches == [0.25...0.5])
        report.tick(position: 0.75, speed: 1, at: at(0.75))
        let skipped = report.flush(.due, paused: false, at: at(25))
        #expect(skipped == nil, "the pause used up the slot at 20 s")
        let lastPing = report.flush(.last, paused: false, at: at(26))
        let last = try #require(lastPing)
        #expect(last.watched.last)
    }

    @Test func pausingSendsTheWatchTime() async throws {
        let rig = Rig()
        let watch = try ping()
        rig.music.set {
            $0.signedIn = true
            $0.watchTime = watch
        }
        await rig.player.start()
        rig.player.play(songs("a", "b"))
        await rig.settle()
        await rig.soundStarts()
        rig.player.onTick()
        rig.audio.currentTime = 0.2
        rig.player.onTick()
        rig.player.togglePlayPause()
        await rig.settle()
        let sent = try #require(rig.music.calls.first { $0.hasPrefix("watchtime") })
        #expect(sent.contains("st=0.000&et=0.200") && sent.contains("state=paused"))

        rig.player.next()
        await rig.settle()
        await rig.soundStarts()
        let last = try #require(rig.music.calls.last { $0.hasPrefix("watchtime") })
        #expect(last.contains("final=1") && !last.contains("st="), "the next play's start ends this one")
    }

    @Test func anOldPlaysWatchTimeNeverGoesOutAfterTheAccountChanges() async throws {
        let rig = Rig()
        let watch = try ping()
        rig.music.set {
            $0.signedIn = true
            $0.watchTime = watch
        }
        await rig.player.start()
        rig.player.play(songs("a"))
        await rig.settle()
        await rig.soundStarts()
        rig.player.onTick()
        rig.audio.currentTime = 0.2
        rig.player.onTick()
        await rig.player.accountDidChange()
        rig.player.togglePlayPause()
        await rig.settle()
        #expect(!rig.music.calls.contains { $0.hasPrefix("watchtime") })
    }
}
