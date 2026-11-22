import Foundation
import os
import YTMCore

/// Only `PlayerController.recordPlay` calls it, so a play is recorded in one place.
@MainActor final class PlayRecorder {
    private let history: LocalHistory
    private let music: any MusicService
    private let lastFM: any Scrobbling
    private var scrobbler = Scrobbler()
    /// Set while the play is reported to YouTube.
    private var watch: WatchReport?

    init(history: LocalHistory, music: any MusicService, lastFM: any Scrobbling) {
        self.history = history
        self.music = music
        self.lastFM = lastFM
    }

    /// `reportToYouTube` adds the song to the account's history, so its
    /// recommendations and Listen again follow what plays here too, then
    /// reports the time heard. Gapless, repeat and restarting start a play
    /// without stopping, so the last one's time goes first.
    func record(_ track: Track, reportToYouTube: Bool, paused: Bool) {
        flushWatch(.last, paused: paused, reporting: reportToYouTube)
        history.record(track)
        scrobbler.start(track)
        let (music, lastFM) = (music, lastFM)
        Task {
            await lastFM.nowPlaying(track)
        }
        guard reportToYouTube else { return }
        let started = ContinuousClock.now
        watch = WatchReport(started: started)
        Task { [weak self] in
            let result = await Result { try await music.reportPlay(videoId: track.id) }
            guard let self, watch?.started == started else { return }
            switch result {
            case .success(let ping?): watch?.answered(ping)
            case .success(nil): watch = nil
            case .failure(let error):
                Logger.playback.warning("could not add a play to the YouTube history: \(sentence(for: error), privacy: .public)")
                watch = nil
            }
        }
    }

    /// Lets the song into Speed dial, then scrobbles it, once enough of its
    /// `length` seconds has been heard, and sends its watch time when due.
    func heard(position: Double, length: Double, speed: Double, reporting: Bool) {
        watch?.tick(position: position, speed: speed, at: .now)
        flushWatch(.due, paused: false, reporting: reporting)
        let (heard, scrobble) = scrobbler.heard(position: position, length: length, speed: speed)
        if let heard { history.markHeard(heard.id) }
        guard let play = scrobble else { return }
        let lastFM = lastFM
        Task {
            await lastFM.scrobble(play.track, startedAt: play.startedAt)
        }
    }

    /// Without `reporting`, signed out or with the YouTube history off, the play's watch time is dropped.
    /// Quitting mid-song loses what was heard since the last ping, as on Windows.
    func flushWatch(_ flush: WatchReport.Flush, paused: Bool, reporting: Bool) {
        guard reporting else {
            watch = nil
            return
        }
        let sending = watch?.flush(flush, paused: paused, at: .now)
        if flush == .last { watch = nil }
        guard let sending else { return }
        let music = music
        Task {
            do {
                try await music.reportWatchTime(sending.ping, sending.watched)
            } catch {
                Logger.playback.debug("could not report the watch time: \(sentence(for: error), privacy: .public)")
            }
        }
    }

    func seeked() {
        watch?.seeked()
    }

    /// An old play's URL never goes out with another account's cookie.
    func forgetWatch() {
        watch = nil
    }
}
