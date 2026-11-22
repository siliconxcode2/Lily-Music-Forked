import CoreGraphics
import Foundation

final class MemoryCache: @unchecked Sendable {
    // `@unchecked`: NSCache is thread-safe, and this holds nothing else.
    private let cache = NSCache<NSString, CGImage>()

    init(limit: Int) {
        cache.totalCostLimit = limit
    }

    subscript(key: String) -> CGImage? {
        cache.object(forKey: key as NSString)
    }

    /// A lower limit needn't evict anything, nor in any set order, so lowering it empties the cache but for `kept`.
    /// The limit drops first, so an image a fetch inserts meanwhile is held to it.
    func setLimit(_ limit: Int, keeping kept: [String] = []) {
        let lowered = limit < cache.totalCostLimit
        let keep = lowered ? kept.compactMap { key in self[key].map { (key, $0) } } : []
        cache.totalCostLimit = limit
        guard lowered else { return }
        cache.removeAllObjects()
        for (key, image) in keep { insert(image, for: key) }
    }

    func insert(_ image: CGImage, for key: String) {
        cache.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }
}

/// Downloads under way, each shared by everyone waiting for its image.
actor Downloads {
    private struct Download {
        /// Its starter's ID, so a cancelled download that ends late never
        /// answers a newer one's waiters.
        let id: UInt64
        let task: Task<Void, Never>
        /// Told the result when it comes, or nil if they stop waiting.
        var waiters: [UInt64: CheckedContinuation<CGImage?, Never>]
    }

    private var downloads: [String: Download] = [:]
    /// A request for an image being prefetched waits for that download, then
    /// reads it from the URL cache rather than fetching it twice.
    private var prefetches: [String: Task<Void, Never>] = [:]
    private var nextID: UInt64 = 0

    /// Waits for `key`'s image, starting `load` unless it is on its way. A
    /// cancelled caller gets nil at once; the download stops with the last.
    func image(for key: String, load: @escaping @Sendable () async -> CGImage?) async -> CGImage? {
        let id = nextID
        nextID += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Still on this actor: `leave` can only run once this has
                // registered the waiter.
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else if downloads[key] != nil {
                    downloads[key]?.waiters[id] = continuation
                } else {
                    let prefetch = prefetches[key]
                    let task = Task { [weak self] in
                        await prefetch?.value
                        let image = await load()
                        await self?.finish(key, id: id, with: image)
                    }
                    downloads[key] = Download(id: id, task: task, waiters: [id: continuation])
                }
            }
        } onCancel: {
            Task { await self.leave(key, id: id) }
        }
    }

    /// Runs `download`, a prefetch of `key`'s image, unless the image is on
    /// its way already. Once started it outlives its caller, as the page's next
    /// prefetch, or a view waiting on it, wants the same bytes.
    func prefetch(_ key: String, download: @escaping @Sendable () async -> Void) async {
        guard downloads[key] == nil, prefetches[key] == nil else { return }
        let task = Task { await download() }
        prefetches[key] = task
        await task.value
        prefetches[key] = nil
    }

    private func finish(_ key: String, id: UInt64, with image: CGImage?) {
        guard downloads[key]?.id == id, let download = downloads.removeValue(forKey: key) else { return }
        for waiter in download.waiters.values { waiter.resume(returning: image) }
    }

    private func leave(_ key: String, id: UInt64) {
        guard let waiter = downloads[key]?.waiters.removeValue(forKey: id) else { return }
        waiter.resume(returning: nil)
        if downloads[key]?.waiters.isEmpty == true {
            downloads.removeValue(forKey: key)?.task.cancel()
        }
    }
}
