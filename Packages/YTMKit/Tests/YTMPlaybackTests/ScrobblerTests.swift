import Foundation
import Testing
@testable import YTMCore
@testable import YTMPlayback

struct ScrobblerTests {
    private let ms = Duration.milliseconds

    @Test func countsOnlyTimePlayedThrough() {
        #expect(Scrobbler.playedThrough(moved: 0.25, elapsed: ms(250), speed: 1) == 0.25, "a tick")
        #expect(Scrobbler.playedThrough(moved: 5, elapsed: ms(5000), speed: 1) == 5, "a tick held up by the main actor")
        #expect(Scrobbler.playedThrough(moved: 30, elapsed: ms(250), speed: 1) == 0, "a seek")
        #expect(Scrobbler.playedThrough(moved: -30, elapsed: ms(250), speed: 1) == 0, "back")
        #expect(Scrobbler.playedThrough(moved: 0, elapsed: ms(250), speed: 1) == 0, "paused")
        #expect(Scrobbler.playedThrough(moved: 6.5, elapsed: ms(5000), speed: 1.3) == 6.5, "a held-up tick at a faster speed")
        #expect(Scrobbler.playedThrough(moved: 6.5, elapsed: ms(5000), speed: 1) == 0, "too far for the time at 1x")
    }

    @Test func aPlayCountsAfterThirtySecondsOrHalfAShortSong() {
        #expect(!Scrobbler.playCounts(heard: 1, length: 200), "a skip")
        #expect(!Scrobbler.playCounts(heard: 29, length: 200))
        #expect(Scrobbler.playCounts(heard: 30, length: 200))
        #expect(Scrobbler.playCounts(heard: 10, length: 20), "half a short song")
        #expect(!Scrobbler.playCounts(heard: 0, length: 0), "an unknown length")
        #expect(Scrobbler.playCounts(heard: 30, length: 0))
    }

    @Test func aShortSongReachesSpeedDialOnceWithoutAScrobble() {
        var scrobbler = Scrobbler()
        scrobbler.start(song("a"))
        var at = ContinuousClock.now
        _ = scrobbler.heard(position: 0, length: 20, speed: 1, at: at)
        at += .milliseconds(250)
        let sought = scrobbler.heard(position: 9, length: 20, speed: 1, at: at)
        #expect(sought.heard == nil, "a seek counts nothing")
        var position = 9.0
        var heard: [String] = []
        var scrobbled = 0
        for _ in 0..<40 {
            at += .milliseconds(250)
            position += 0.25
            let result = scrobbler.heard(position: position, length: 20, speed: 1, at: at)
            if let track = result.heard { heard.append(track.id) }
            if result.scrobble != nil { scrobbled += 1 }
        }
        #expect(heard == ["a"], "10 s heard of 20, once")
        #expect(scrobbled == 0, "too short for Last.fm")
    }

    @Test func countsHalfATrackOrFourMinutes() {
        #expect(!Scrobbler.counts(heard: 20, length: 30), "30 seconds is too short")
        #expect(!Scrobbler.counts(heard: 89, length: 180))
        #expect(Scrobbler.counts(heard: 90, length: 180))
        #expect(Scrobbler.counts(heard: 240, length: 1200), "four minutes of a long one")
        #expect(!Scrobbler.counts(heard: 239, length: 1200))
    }

    @Test func scrobblesOnceWhatWasHeardCounts() {
        var scrobbler = Scrobbler()
        scrobbler.start(song("a"))
        let start = ContinuousClock.now
        let result1 = scrobbler.heard(position: 0, length: 60, speed: 1, at: start)
        #expect(result1.scrobble == nil)
        let result2 = scrobbler.heard(position: 100, length: 60, speed: 1, at: start + .milliseconds(250))
        #expect(result2.scrobble == nil, "a seek counts nothing")
        var at = start + .milliseconds(250)
        var position = 100.0
        var scrobbled: [String] = []
        for _ in 0..<130 {
            at += .milliseconds(250)
            position += 0.25
            if let play = scrobbler.heard(position: position, length: 60, speed: 1, at: at).scrobble { scrobbled.append(play.track.id) }
        }
        #expect(scrobbled == ["a"], "30 s heard of 60, once")
    }
}
