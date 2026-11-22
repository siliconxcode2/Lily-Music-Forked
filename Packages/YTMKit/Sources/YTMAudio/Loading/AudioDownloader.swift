import Foundation
import Network

/// Keeps songs on the phone for good, outside the play cache and its cap.
public actor AudioDownloader {
    /// Room left on the phone after a download, so it never fills it.
    static let reserveBytes: Int64 = 500 << 20
    static let progressStep = 0.05

    private let directory: URL
    /// Made on first use, as it clears unfinished parts from the disk.
    private lazy var cache = AudioCache(.init(directory: directory, limit: .max))
    private let source: any ByteSource

    /// `proxies` is asked for at the first download, off the main actor.
    public init(directory: URL, proxies: @escaping @Sendable () -> [ProxyConfiguration] = { [] }) {
        self.directory = directory
        source = HTTPByteSource(proxies: proxies)
    }

    public nonisolated func file(for key: String) -> URL {
        directory.appending(path: AudioCache.safeName(key))
    }

    /// Throws `CancellationError` when cancelled and `AudioFailure` otherwise.
    public func download(_ item: AudioItem, progress: @Sendable (Double) -> Void) async throws {
        if cache.completeFile(for: item.cacheKey, length: item.contentLength) != nil || adoptPlayed(item) { return }
        try checkRoom(for: item.contentLength)
        let loader = try StreamLoader(item: item, cache: cache)
        var reported = 0.0
        let failure = await loader.run(source: source) { _ in
            guard loader.total > 0 else { return }
            let fraction = Double(loader.available) / Double(loader.total)
            if fraction - reported >= Self.progressStep {
                reported = fraction
                progress(fraction)
            }
        }
        if let failure { throw failure }
        guard loader.isComplete else { throw CancellationError() }
    }

    public func remove(_ keys: [String]) {
        for key in keys { cache.remove(key) }
    }

    /// Clears files left by downloads the app no longer knows of.
    public func removeAll(except keys: Set<String>) {
        cache.removeAll(except: keys)
    }

    /// A song played lately may already be whole in the play cache.
    private func adoptPlayed(_ item: AudioItem) -> Bool {
        let played = AudioCache.defaultDirectory.appending(path: AudioCache.safeName(item.cacheKey))
        guard AudioCache.isWhole(played, length: item.contentLength) else { return false }
        return cache.adopt(played, as: item.cacheKey)
    }

    private func checkRoom(for length: Int64) throws(AudioFailure) {
        let free = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        if let free, free < max(length, 0) + Self.reserveBytes { throw .storage }
    }
}
