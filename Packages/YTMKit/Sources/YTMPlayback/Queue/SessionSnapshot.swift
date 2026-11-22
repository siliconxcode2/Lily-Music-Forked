import Foundation
import YTMCore

/// The queue and position kept between launches as session.json.
struct SessionSnapshot: Codable, Equatable, Sendable {
    /// Longest queue kept between launches.
    static let limit = 500

    var queue: [Track]
    var index: Int
    var position: Double
    /// Length of the current song, which feed cards do not carry.
    var duration: Double
    /// Queue entries Smart Shuffle put in.
    var recommended: [Int]
    /// The current song's stream, so a play soon after launch needn't ask YouTube again.
    var stream: KeptStream? = nil

    struct KeptStream: Codable, Equatable, Sendable {
        var stream: ResolvedStream
        var resolved: Date
    }

    /// All of the queue, or the window around `index` if it is long.
    static func window(count: Int, index: Int) -> Range<Int> {
        guard count > limit else { return 0..<count }
        let start = max(index - limit / 2, 0)
        return start..<min(start + limit, count)
    }

    /// Nil for an empty queue.
    init?(_ queue: Queue<Track>, position: Double, duration: Double) {
        guard let current = queue.currentIndex else { return nil }
        let window = Self.window(count: queue.count, index: current)
        self.queue = Array(queue.items[window])
        index = current - window.lowerBound
        self.position = position
        self.duration = duration
        recommended = queue.recommendedIndices.filter(window.contains).map { $0 - window.lowerBound }
    }

    /// Nil when session.json is missing, can't be read or names no entry.
    @concurrent
    static func load(from store: FileStore) async -> SessionSnapshot? {
        store.load(SessionSnapshot.self, from: .session).flatMap { $0.queue.indices.contains($0.index) ? $0 : nil }
    }
}

extension PlayerController {
    /// Debounced, so skipping through songs costs one write.
    func persistSoon() {
        sessionSaving.schedule { [weak self] in self?.writeSession() }
    }

    /// Writes the session, history and settings now, as when the app leaves
    /// the foreground.
    public func persistSession() {
        sessionSaving.cancel()
        writeSession()
        history.saveNow()
        settings.saveNow()
        downloads.saveIfPending()
    }

    private func writeSession() {
        let position = if let resume = playback.resume, resume.id == current?.id { resume.position }
            else if playback.started { audio.currentTime } else { 0.0 }
        guard var snapshot = SessionSnapshot(queue, position: position, duration: playback.duration) else { return }
        if let id = current?.id, let kept = prefetcher.kept(id) {
            snapshot.stream = .init(stream: kept.stream, resolved: .now.addingTimeInterval(-(ContinuousClock.now - kept.resolvedAt).seconds))
        }
        store.save(snapshot, to: .session)
    }

    /// Shows the last launch's song, paused, and returns it.
    func restoreSession() async -> Track? {
        guard let session = await SessionSnapshot.load(from: store), current == nil else { return nil }
        let track = session.queue[session.index]
        replaceQueue(with: session.queue, start: session.index, shuffle: false)
        queue.markRecommended(session.recommended)
        playback.resume = (track.id, session.position)
        playback.duration = track.duration.map(Double.init) ?? session.duration
        playback.heldPosition = session.position
        if let saved = session.stream {
            let age = Duration.seconds(Date.now.timeIntervalSince(saved.resolved))
            // Only with half its hour left, so it still covers a play well after launch; not if the
            // clock was set back, which would keep it fresh for ever.
            if age >= .zero, age < StreamPrefetcher.freshFor / 2 { prefetcher.store(track.id, .init(stream: saved.stream, resolvedAt: .now - age, epoch: prefetcher.epoch)) }
        }
        current = track
        duration = playback.duration
        nowPlaying?.show(track, duration: duration)
        publishPlayback()
        return track
    }

    /// The rating loads only if none has been set or loaded since `rating`,
    /// the rating generation at restore.
    func warmUp(_ restored: Track?, rating: UInt64) {
        preparePremium()
        guard let restored, current?.id == restored.id else { return }
        if ratingGeneration == rating { loadRating(of: restored.id) }
        // So the first play needn't wait on YouTube. Not warmed: the play
        // fetches the start itself.
        guard isStopped else { return }
        resolveAhead(restored, warming: false)
    }
}
