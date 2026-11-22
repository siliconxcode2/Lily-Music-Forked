import Foundation
import os
import YTMCore

/// Swaps music videos for their song versions, which are audio only and have
/// Premium formats, only once the song's own stream is ready, so nothing waits.
struct SongVersionSwapper {
    /// Most videos remembered; past it the cache starts over.
    static let limit = 256

    private enum Lookup {
        case pending
        case known(Track?)
    }

    private var lookups: [String: Lookup] = [:]

    func knownSong(for videoId: String) -> Track? {
        if case .known(let song?) = lookups[videoId] { song } else { nil }
    }

    /// False when the lookup is already under way or done.
    mutating func beginLookup(_ videoId: String) -> Bool {
        guard lookups[videoId] == nil else { return false }
        if lookups.count >= Self.limit {
            lookups = lookups.filter { if case .pending = $0.value { true } else { false } }
        }
        lookups[videoId] = .pending
        return true
    }

    /// A failed lookup counts as none, so it is not retried per song.
    mutating func found(_ song: Track?, for videoId: String) {
        lookups[videoId] = .known(song)
    }
}

extension PlayerController {
    /// Returns at once; the queue changes later.
    func swapInSongVersion(_ next: Track) {
        if let song = songVersions.knownSong(for: next.id) {
            prefetchSongVersion(of: next.id, song)
            return
        }
        guard songVersions.beginLookup(next.id) else { return }
        let music = music
        Task { [weak self] in
            let result = await Result { try await music.songVersion(of: next) }
            guard let self else { return }
            if case .failure(let error) = result {
                Logger.playback.debug("\(next.id, privacy: .public): could not look for a song version: \(sentence(for: error), privacy: .public)")
            }
            let song = try? result.get()
            songVersions.found(song, for: next.id)
            if let song { prefetchSongVersion(of: next.id, song) }
        }
    }

    private func prefetchSongVersion(of videoId: String, _ song: Track) {
        guard !prefetcher.isPending(song.id) else { return }
        if prefetcher.has(song.id) {
            putSongVersion(song, for: videoId)
            return
        }
        // Kept only if the swap succeeds: the video may have left the queue,
        // or started playing, meanwhile.
        resolveAhead(song) { $0.putSongVersion(song, for: videoId) }
    }

    /// Never swaps the video while it is playing; drops its prefetched stream.
    @discardableResult
    private func putSongVersion(_ song: Track, for videoId: String) -> Bool {
        guard current?.id != videoId, !queue.replace(where: { $0.id == videoId }, with: song).isEmpty else { return false }
        prefetcher.remove(videoId)
        Logger.playback.info("\(videoId, privacy: .public): playing its song version, \(song.id, privacy: .public)")
        return true
    }
}
