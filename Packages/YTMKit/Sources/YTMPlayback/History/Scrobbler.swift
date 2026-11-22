import Foundation
import YTMCore

/// Only time played through counts towards a play or a scrobble, so seeks
/// and stalls add nothing.
struct Scrobbler {
    private struct Listening {
        let track: Track
        let startedAt: Date
        var heard = 0.0
        /// Heard long enough for Speed dial.
        var counted = false
        var lastTick: (position: Double, at: ContinuousClock.Instant)?
    }

    private var playing: Listening?

    /// Forward by no more than the song time `elapsed` plays at `speed`, so a
    /// seek adds nothing while a delayed tick loses nothing, as the sound plays
    /// on its own thread.
    static func playedThrough(moved: Double, elapsed: Duration, speed: Double) -> Double {
        moved > 0 && moved <= (elapsed + PlayerController.tick).seconds * speed ? moved : 0
    }

    /// Speed dial's rule: 30 seconds, or half of a song under a minute; an
    /// unknown length needs the full 30.
    static func playCounts(heard: Double, length: Double) -> Bool {
        heard >= (length > 0 ? min(30, length / 2) : 30)
    }

    /// Last.fm's rule: the song is over 30 seconds, and half of it or four
    /// minutes has played.
    static func counts(heard: Double, length: Double) -> Bool {
        length > 30 && heard >= min(length / 2, 240)
    }

    mutating func start(_ track: Track, at date: Date = .now) {
        playing = Listening(track: track, startedAt: date)
    }

    /// `heard` is the song once its play counts for Speed dial, `scrobble` the
    /// play once it counts for Last.fm, each only that once. Last.fm's rule is
    /// never met before Speed dial's, so ending the listening there loses nothing.
    mutating func heard(
        position: Double, length: Double, speed: Double, at now: ContinuousClock.Instant = .now
    ) -> (heard: Track?, scrobble: (track: Track, startedAt: Date)?) {
        guard var listening = playing else { return (nil, nil) }
        if let last = listening.lastTick {
            listening.heard += Self.playedThrough(moved: position - last.position, elapsed: now - last.at, speed: speed)
        }
        listening.lastTick = (position, now)
        var heard: Track?
        if !listening.counted, Self.playCounts(heard: listening.heard, length: length) {
            listening.counted = true
            heard = listening.track
        }
        guard Self.counts(heard: listening.heard, length: length) else {
            playing = listening
            return (heard, nil)
        }
        playing = nil
        return (heard, (track: listening.track, startedAt: listening.startedAt))
    }
}

extension Duration {
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }
}
