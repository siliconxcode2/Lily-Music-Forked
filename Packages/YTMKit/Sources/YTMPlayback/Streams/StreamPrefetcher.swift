import Foundation
import os
import YTMCore

/// Streams resolved ahead for the next song, and kept from songs played for
/// previous or repeat. Stream URLs last about six hours; one older than an
/// hour is asked for again, unless it is the playing song's and wholly cached.
struct StreamPrefetcher {
    static let freshFor = Duration.seconds(60 * 60)

    struct Prefetched {
        let stream: ResolvedStream
        let resolvedAt: ContinuousClock.Instant
        /// So `store` can refuse one asked for before a `clear`.
        let epoch: Int
    }

    private var streams: [String: Prefetched] = [:]
    /// The playing song's, kept however old, as a replay of a whole file plays from the cache.
    private var playing: (id: String, prefetched: Prefetched)?
    /// So a song started or queued meanwhile waits on its resolve rather than
    /// asking again.
    private var pending: [String: Task<ResolvedStream, any Error>] = [:]
    /// Bumped by `clear`, so a stream resolved before it, for the old
    /// quality or account, is never kept again.
    private(set) var epoch = 0

    func has(_ id: String, at now: ContinuousClock.Instant = .now) -> Bool {
        kept(id, at: now) != nil
    }

    func kept(_ id: String, at now: ContinuousClock.Instant = .now) -> Prefetched? {
        streams[id].flatMap { now - $0.resolvedAt < Self.freshFor ? $0 : nil }
    }

    mutating func take(_ id: String, at now: ContinuousClock.Instant = .now) -> Prefetched? {
        defer { streams[id] = nil }
        return kept(id, at: now)
    }

    /// Drops stale streams too. One asked for before a `clear` is not kept.
    /// Nor is a downloaded file's, as it may be removed before it plays. Returns whether it was kept.
    @discardableResult
    mutating func store(_ id: String, _ prefetched: Prefetched, at now: ContinuousClock.Instant = .now) -> Bool {
        guard prefetched.epoch == epoch, !prefetched.stream.url.isFileURL else { return false }
        streams = streams.filter { now - $0.value.resolvedAt < Self.freshFor }
        streams[id] = prefetched
        return true
    }

    /// As `store`, and kept as the playing song's.
    mutating func storePlaying(_ id: String, _ prefetched: Prefetched, at now: ContinuousClock.Instant = .now) {
        playing = store(id, prefetched, at: now) ? (id, prefetched) : nil
    }

    /// The playing song's stream, however old.
    func held(_ id: String) -> Prefetched? {
        playing?.id == id ? playing?.prefetched : nil
    }

    mutating func remove(_ id: String) {
        streams[id] = nil
        if playing?.id == id { playing = nil }
    }

    func isPending(_ id: String) -> Bool {
        pending[id] != nil
    }

    /// Hand the task to `finish` as it lands.
    mutating func begin(_ id: String, _ resolve: @escaping @Sendable () async throws -> ResolvedStream) -> Task<ResolvedStream, any Error> {
        let task = Task { try await resolve() }
        pending[id] = task
        return task
    }

    /// The caller then keeps the stream; the task's own completion stores nothing.
    mutating func takePending(_ id: String) -> Task<ResolvedStream, any Error>? {
        pending.removeValue(forKey: id)
    }

    /// Left in place, so its own completion still keeps the stream.
    func pendingTask(_ id: String) -> Task<ResolvedStream, any Error>? {
        pending[id]
    }

    /// False, changing nothing, when the task was taken meanwhile or dropped
    /// by `clear`.
    mutating func finish(_ id: String, _ task: Task<ResolvedStream, any Error>) -> Bool {
        guard pending[id] == task else { return false }
        pending[id] = nil
        return true
    }

    mutating func clear() {
        epoch += 1
        streams.removeAll()
        playing = nil
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }
}

extension PlayerController {
    /// Smart Shuffle goes first, as the next song may be one of its
    /// recommendations. Never waits.
    func prefetchNext() {
        topUpSmartShuffle()
        guard let next = queue.peekNext(repeat: repeatMode) else { return }
        // A downloaded video stays, as its song version may need the network.
        if next.isVideo, localStream(next.id) == nil { swapInSongVersion(next) }
        prefetchLyrics(of: songVersions.knownSong(for: next.id)?.id ?? next.id)
        // Both sizes the playing song shows, so its artwork and colours are
        // there on the first frame.
        if let art = next.thumbnail {
            Task { await ImagePipeline.shared.image(for: art, pixelEdge: ImagePipeline.playerEdge) }
            Task { await ImagePipeline.shared.image(for: art, pixelEdge: ImagePipeline.smallEdge) }
        }
        // A known song version resolves in the video's place, unless the video
        // is playing, as on repeat. One still being looked up resolves too.
        let replaced = songVersions.knownSong(for: next.id) != nil && current?.id != next.id
        guard !replaced else { return }
        resolveAhead(next)
    }

    /// The stream is kept only if `keep` says so once it lands. `warming` has
    /// the engine fetch its start too while it is still next.
    func resolveAhead(
        _ track: Track, warming: Bool = true, keep: @escaping @MainActor (PlayerController) -> Bool = { _ in true }
    ) {
        guard localStream(track.id) == nil, heldStream(track.id) == nil else { return }
        if let kept = prefetcher.kept(track.id) {
            // A kept stream may have lost its part file since; the engine skips
            // a file cached or open.
            if warming, current?.id != track.id { warm(track, kept.stream) }
            return
        }
        guard !prefetcher.isPending(track.id) else { return }
        let task = prefetcher.begin(track.id, resolver(for: track.id))
        Task { [weak self] in
            let result = await task.result
            guard let self, prefetcher.finish(track.id, task) else { return }
            switch result {
            case .success(let stream):
                guard keep(self) else { return }
                prefetcher.store(track.id, .init(stream: stream, resolvedAt: .now, epoch: prefetcher.epoch))
                if warming { warm(track, stream) }
            case .failure(let error):
                Logger.playback.debug("\(track.id, privacy: .public): could not resolve ahead: \(sentence(for: error), privacy: .public)")
            }
        }
    }

    /// Unless `owning`, a pending resolve is waited on but left in place, so
    /// cancelling the wait, as a skip does to gapless queueing, leaves it running.
    func streamSource(for id: String, owning: Bool = true) -> @Sendable () async throws -> StreamPrefetcher.Prefetched {
        if let prefetched = localStream(id) ?? heldStream(id) ?? prefetcher.take(id) { return { prefetched } }
        let epoch = prefetcher.epoch
        if !owning, let pending = prefetcher.pendingTask(id) {
            return { .init(stream: try await pending.value, resolvedAt: .now, epoch: epoch) }
        }
        if let pending = prefetcher.takePending(id) {
            return {
                let stream = try await withTaskCancellationHandler { try await pending.value } onCancel: { pending.cancel() }
                return .init(stream: stream, resolvedAt: .now, epoch: epoch)
            }
        }
        let resolve = resolver(for: id)
        return { .init(stream: try await resolve(), resolvedAt: .now, epoch: epoch) }
    }

    /// The playing song's stream, however old, while the engine holds all of it, as on repeat-one or a restart:
    /// of a file partly cached, the rest needs a URL that works.
    func heldStream(_ id: String) -> StreamPrefetcher.Prefetched? {
        id == current?.id && audio.bufferedFraction >= 1 ? prefetcher.held(id) : nil
    }

    /// Only while `track` is still next: the engine warms one song, and a
    /// stream landing late for another would replace the real next song's.
    func warm(_ track: Track, _ stream: ResolvedStream) {
        guard queue.peekNext(repeat: repeatMode)?.id == track.id,
              let item = try? audioItem(for: track, stream: stream) else { return }
        audio.warm(item)
    }
}
