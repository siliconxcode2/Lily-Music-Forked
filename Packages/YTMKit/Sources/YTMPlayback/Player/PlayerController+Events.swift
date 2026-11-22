import Foundation
import os
import YTMAudio
import YTMCore

extension PlayerController {
    func handle(_ event: AudioEvent) {
        switch event {
        case .started(let id):
            if id == playback.itemID { soundStarted() }
        case .advanced(let id):
            if let queued = gapless.queued, queued.itemID == id {
                gapless.forget()
                advanceGapless(to: queued)
            } else {
                // A song the player no longer had queued crossed over, as the
                // queue changed at that very moment; play what it says now.
                gapless.forget()
                next(user: false)
            }
        case .finished:
            next(user: false)
        case .failed(let id, let message):
            // The queued song failed to open: the current one ends with
            // `finished`, and the next then loads afresh.
            if id == gapless.queued?.itemID {
                gapless.queuedFailed = true
                // Its stream may be kept too; the song then resolves afresh.
                if let trackID = gapless.queued?.trackID { prefetcher.remove(trackID) }
            } else if id == playback.itemID {
                playbackFailed(current?.title ?? "", message)
            }
        case .dropped(let id):
            // The queued song's stream is kept, unlike for `failed`, so it rides out the drop as it
            // plays rather than failing to resolve offline.
            if id == playback.itemID { connectionLost() }
        case .buffering(let stalled):
            playback.stalled = stalled
            updateBuffering()
            publishPlayback()
        case .nextDropped:
            gapless.unqueue(into: &prefetcher)
        }
    }

    /// Counts as a play, unless it carries on one already recorded, as a
    /// Premium song retried on the free stream.
    private func soundStarted() {
        playback.started = true
        playback.loading = false
        // `failures` stays: once googlevideo cuts every client off, each song sounds and then fails, and those count.
        playback.resume = nil
        playback.reopen = nil
        let recorded = playback.playRecorded == playback.generation
        playback.playRecorded = nil
        if !recorded { recordPlay() }
        if let requested = playback.requestedAt {
            let waited = Int(((ContinuousClock.now - requested).seconds * 1000).rounded())
            let path = playback.currentPremium ? "Premium" : "free"
            Logger.playback.info("first sound after \(waited, privacy: .public) ms (\(path, privacy: .public), \(self.stream?.badge ?? "", privacy: .public))")
            playback.requestedAt = nil
        }
        updateBuffering()
        publishPlayback()
        syncPremiumStatus()
        extendWithRadioIfEnding()
        prefetchNext()
    }

    /// The one place a play is recorded.
    func recordPlay() {
        guard let track = queue.current else { return }
        recorder.record(track, reportToYouTube: reportsToYouTube, paused: !isPlaying)
        persistSoon()
    }
}
