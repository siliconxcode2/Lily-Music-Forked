/// googlevideo's first answer for a rarely played song can take over half a second, so the
/// likely next item's start is fetched early into the part file its download carries on from.
extension PlaybackEngine {
    struct Warmed {
        let item: AudioItem
        let loader: StreamLoader
        let task: Task<Void, Never>
    }

    /// Replaces any earlier warm-up.
    func warm(_ item: AudioItem) {
        guard item.contentLength > 0, !item.url.isFileURL, warmed?.item.url != item.url,
              ![heard, producing, next].contains(where: { $0?.item.cacheKey == item.cacheKey }),
              cache.completeFile(for: item.cacheKey, length: item.contentLength) == nil,
              let loader = try? StreamLoader(item: item, cache: cache) else { return }
        warmed?.task.cancel()
        warmed = Warmed(item: item, loader: loader, task: Task { [self] in await loader.warm(source: source) })
    }

    /// Keeps a dropped next item's download as the warm-up, so reopening it carries on from
    /// disk. An existing warm-up, for the item now likely next, wins.
    func keepWarm(_ track: Track) {
        let task = track.download
        track.cancel()
        guard warmed == nil, let task, !track.loader.isComplete, track.failure == nil, track.item.contentLength > 0 else { return }
        warmed = Warmed(item: track.item, loader: track.loader, task: task)
    }

    func takeWarmed(_ item: AudioItem) -> Warmed? {
        guard let warmed, warmed.item.url == item.url, warmed.item.cacheKey == item.cacheKey else { return nil }
        self.warmed = nil
        return warmed
    }
}
