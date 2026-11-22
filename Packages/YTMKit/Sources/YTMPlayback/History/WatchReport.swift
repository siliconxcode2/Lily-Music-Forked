import Foundation
import os
import YTMCore

/// A play's watch-time pings, as the web player sends them: the stretches heard, on YouTube's
/// schedule, on pausing and as the play ends. Apart from `Scrobbler`, whose listening ends once
/// a play scrobbles.
struct WatchReport {
    enum Flush {
        /// On the web player's schedule.
        case due
        /// On pausing.
        case now
        /// The play ended.
        case last
    }

    /// Also tells this play from a replay of the same song.
    let started: ContinuousClock.Instant
    /// Where they go, once the play's report is answered.
    private var ping: WatchTime?
    private var sent = 0
    /// Since `started`.
    private var nextAt = Duration.zero
    /// Heard since the last ping, in song seconds.
    private(set) var stretches: [ClosedRange<Double>] = []
    /// The end of the last stretch heard.
    private var position = 0.0
    private var lastTick: (position: Double, at: ContinuousClock.Instant)?

    init(started: ContinuousClock.Instant) {
        self.started = started
    }

    mutating func answered(_ ping: WatchTime) {
        self.ping = ping
        nextAt = ping.due(0, sent: .zero)
    }

    /// Ticks stop while paused, where a seek could pass for time played through.
    mutating func seeked() {
        lastTick = nil
    }

    /// Only time played through counts, as for a scrobble.
    mutating func tick(position: Double, speed: Double, at now: ContinuousClock.Instant) {
        if let last = lastTick, Scrobbler.playedThrough(moved: position - last.position, elapsed: now - last.at, speed: speed) > 0 {
            // `last.position` is the very value that ended a stretch played on, so a seek splits them.
            if let end = stretches.last?.upperBound, end == last.position {
                stretches[stretches.count - 1] = stretches[stretches.count - 1].lowerBound...position
            } else {
                stretches.append(last.position...position)
            }
            self.position = position
        }
        lastTick = (position, now)
    }

    /// The ping to send now, if one is due and the play's report has said where.
    mutating func flush(_ flush: Flush, paused: Bool, at now: ContinuousClock.Instant) -> (ping: WatchTime, watched: Watched)? {
        let elapsed = now - started
        let heard = !stretches.isEmpty
        let due = switch flush {
        case .due: heard && elapsed >= nextAt
        case .now: heard
        case .last: true
        }
        guard due, let ping else { return nil }
        let watched = Watched(stretches: stretches, position: position, elapsed: elapsed, paused: paused, last: flush == .last)
        stretches = []
        sent += 1
        nextAt = ping.due(sent, sent: elapsed)
        // What it reports, without the ping's URL and its tokens. A mutating func's log can't read `self`, and the
        // spans are written out only with debug logging on.
        let count = sent
        Logger.playback.debug(
            "watch time \(count) at \(elapsed.seconds, format: .fixed(precision: 0)) s: heard [\(watched.stretches.map { String(format: "%.1f-%.1f", $0.lowerBound, $0.upperBound) }.joined(separator: ", "), privacy: .public)], at \(watched.position, format: .fixed(precision: 1)) s\(watched.paused ? ", paused" : "", privacy: .public)\(watched.last ? ", final" : "", privacy: .public)"
        )
        return (ping, watched)
    }
}
