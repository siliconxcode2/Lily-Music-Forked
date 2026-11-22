import Foundation
import os
import YTMAudio
import YTMCore

/// Queues the next song in the engine shortly before the current one ends,
/// so it follows without a gap or fades in.
struct GaplessScheduler {
    /// Wall time for the next stream to start downloading and its decoder to open. A crossfade
    /// adds its length and the silence it may cut, which the engine holds back, both in song time.
    static let leadSeconds = 15.0

    struct Queued {
        let trackID: String
        /// The engine's ID for it, so its events can be told from the current one's.
        let itemID: String
        let prefetched: StreamPrefetcher.Prefetched
    }

    private(set) var queued: Queued?
    /// The engine couldn't open the queued stream, so `unqueue` drops it. Only a
    /// flag, as the event may be late for a song queued since.
    var queuedFailed = false
    /// The song last tried for queueing, so a failure is not retried every tick.
    private(set) var tried: String?

    /// Album tracks in order are often written to run straight on, so are never faded into.
    static func inAlbumOrder(_ current: Track?, _ next: Track) -> Bool {
        guard let current, let album = current.album?.id, album == next.album?.id else { return false }
        guard let a = current.trackNumber, let b = next.trackNumber else { return true }
        return a < .max && a + 1 == b
    }

    /// In song time, which passes `speed` times as fast as wall time.
    static func lead(crossfade: Double, speed: Double) -> Double {
        let open = leadSeconds * speed
        return crossfade > 0 ? open + crossfade + AudioPlayer.silenceTrimSeconds : open
    }

    /// `stale`: the queued song is no longer next; `due`: the song to queue now, with its fade.
    func plan(
        position: Double, duration: Double, started: Bool, current: Track?, next: Track?, crossfadeSeconds: Double?, speed: Double
    ) -> (stale: Bool, due: (id: String, crossfade: Double)?) {
        let fade = if let crossfadeSeconds, let next, !Self.inAlbumOrder(current, next) { crossfadeSeconds } else { 0.0 }
        let stale = queued.map { $0.trackID != next?.id } ?? false
        let nearEnd = started && duration > 0 && duration - position <= Self.lead(crossfade: fade, speed: speed) && (queued == nil || stale)
        guard nearEnd, let next, tried != next.id else { return (stale, nil) }
        return (stale, (next.id, fade))
    }

    mutating func markTried(_ id: String) {
        tried = id
    }

    mutating func setQueued(_ queued: Queued) {
        self.queued = queued
        queuedFailed = false
    }

    /// The engine's own copy must be dropped separately, with `setNext(nil)`.
    mutating func forget() {
        queued = nil
        queuedFailed = false
        tried = nil
    }

    /// As `forget`, but hands the stream back to `prefetcher`. Not for a quality
    /// change or a Premium retry, which must drop it.
    mutating func unqueue(into prefetcher: inout StreamPrefetcher) {
        if let queued, !queuedFailed {
            prefetcher.store(queued.trackID, queued.prefetched)
        }
        forget()
    }
}

extension PlayerController {
    /// Run every tick while playing; copies nothing until a song is due.
    func updateGapless(at position: Double) {
        let next = queue.peekNext(repeat: repeatMode)
        let plan = gapless.plan(
            position: position, duration: playback.duration, started: playback.started,
            current: queue.current, next: next, crossfadeSeconds: settings.value.crossfade ? audio.crossfadeSeconds : nil,
            speed: audio.speed
        )
        if plan.stale { dropQueuedNext() }
        guard let (nextID, fade) = plan.due, let next else { return }
        gapless.markTried(nextID)
        // A resolve ahead is only waited on, so a skip that cancels this still
        // starts the song from it; one handed back keeps its resolve time.
        let source = streamSource(for: nextID, owning: false)
        let generation = playback.generation
        queueing = Task { [weak self] in
            let result = await Result(source)
            guard let self, !Task.isCancelled, playback.generation == generation,
                  queue.peekNext(repeat: repeatMode)?.id == nextID else { return }
            do {
                let prefetched = try result.get()
                let item = try audioItem(for: next, stream: prefetched.stream)
                audio.setNext(item, crossfade: fade > 0)
                gapless.setQueued(.init(trackID: nextID, itemID: item.id, prefetched: prefetched))
            } catch {
                Logger.playback.debug("could not queue the next track: \(sentence(for: error), privacy: .public)")
            }
        }
    }

    /// Keeps the stream for later; the next tick queues the song again, with the
    /// settings as they are then.
    func dropQueuedNext() {
        queueing?.cancel()
        guard gapless.queued != nil else { return gapless.forget() }
        gapless.unqueue(into: &prefetcher)
        audio.setNext(nil, crossfade: false)
    }

    /// The queued song became audible: moves the queue on without loading anything.
    func advanceGapless(to queued: GaplessScheduler.Queued) {
        guard let track = queue.advance(user: false, repeat: repeatMode), track.id == queued.trackID else {
            // The queue changed under the engine; play what it says now.
            startCurrent()
            return
        }
        playback.generation += 1
        playback.started = true
        playback.failures = 0
        playback.duration = track.seconds
        playback.requestedAt = nil
        playback.resume = nil
        playback.reopen = nil
        playback.itemID = queued.itemID
        present(track, at: 0)
        recordPlay()
        show(queued.prefetched.stream)
        // Kept for previous, a jump back or repeat one, as `play` keeps its song.
        prefetcher.storePlaying(track.id, queued.prefetched)
        updateBuffering()
        publishPlayback()
        extendWithRadioIfEnding()
        prefetchNext()
    }
}
