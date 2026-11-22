import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import os

/// Artwork decoded off the main actor at the size shown, from memory, then the
/// downloads' artwork, then `HTTP.media`'s disk URL cache, then the network.
public final class ImagePipeline: Sendable {
    public static let shared = ImagePipeline()

    /// Now Playing's artwork in pixels (the phone's width less its margins,
    /// at 3x), shared with the lock screen so both use one decode.
    public static let playerEdge = 1080
    /// Any artwork drawn 56 points or smaller (56 at 3x), in pixels, so a
    /// row's copy, the mini player's and the prefetched one share one decode.
    public static let smallEdge = 168

    /// Decoded artwork kept, in bytes: enough for a Home feed's cards and the
    /// player's 1080-pixel copy to outlast a scroll.
    static let memoryLimit = 96 << 20
    /// The limit while the app is in the background, where nothing draws artwork: the playing song's player and row
    /// copies, kept for its return, and the next song's, which `StreamPrefetcher` decodes for the lock screen
    /// (4.5 MB each at 1080 pixels, over Windows's whole 2 MB).
    static let hiddenLimit = 10 << 20
    /// Prefetches at once per page, besides any its last run left finishing: few, so the
    /// artwork a view asks for itself never queues behind a page's worth for the media host's connections.
    private static let prefetchWidth = 4
    private static let log = Logger(subsystem: "Lily", category: "ImagePipeline")
    /// Downloaded songs' artwork, at the player's size, which serves every smaller one.
    private static let kept = FileStore.shared.downloads.appending(path: "Artwork", directoryHint: .isDirectory)
    /// How long the URL cache's copy is used before it is fetched again, as artwork can change under the same URL.
    private static let maxAge: TimeInterval = 30 * 24 * 60 * 60
    /// HTTP's dates, as `Sun, 06 Nov 1994 08:49:37 GMT`.
    private static let httpDate = Date.ParseStrategy(
        format: "\(weekday: .abbreviated), \(day: .twoDigits) \(month: .abbreviated) \(year: .defaultDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits) GMT",
        locale: Locale(identifier: "en_US_POSIX"), timeZone: .gmt
    )

    let memory = MemoryCache(limit: memoryLimit)
    private let downloads = Downloads()

    /// Artwork from `url` scaled so its shorter side is `pixelEdge` pixels,
    /// or nil when it can't be had or the caller was cancelled.
    public func image(for url: String, pixelEdge: Int) async -> CGImage? {
        let key = Self.key(url, pixelEdge)
        if let image = memory[key] { return image }
        return await downloads.image(for: key) { [memory] in
            // Another request may have finished it since the check above.
            if let image = memory[key] { return image }
            guard let image = await Self.fetch(url, edge: pixelEdge) else { return nil }
            memory.insert(image, for: key)
            return image
        }
    }

    /// Empties the memory cache but for `playing`'s player and row copies, which Now Playing and the mini player
    /// show on the app's return, and holds it to `hiddenLimit` while the app is in the background; once back, it
    /// grows again. Artwork on screen stays, as its views hold it, so only what Back or a scroll would reuse goes,
    /// to be read from disk again.
    public func setHidden(_ hidden: Bool, keeping playing: String? = nil) {
        let kept = playing.map { url in [Self.playerEdge, Self.smallEdge].map { Self.key(url, $0) } } ?? []
        memory.setLimit(hidden ? Self.hiddenLimit : Self.memoryLimit, keeping: kept)
    }

    /// Artwork already decoded at `pixelEdge`, without fetching.
    public func cachedImage(for url: String, pixelEdge: Int) -> CGImage? {
        memory[Self.key(url, pixelEdge)]
    }

    /// Downloads artwork into the disk URL cache without decoding it, so memory
    /// stays bounded. Nothing more starts once the caller is cancelled.
    public func prefetch(_ urls: [String], pixelEdge: Int) async {
        await withTaskGroup(of: Void.self) { group in
            var seen = Set<String>()
            var running = 0
            for url in urls {
                if running == Self.prefetchWidth {
                    _ = await group.next()
                    running -= 1
                }
                guard !Task.isCancelled else { return }
                let key = Self.key(url, pixelEdge)
                guard seen.insert(key).inserted, memory[key] == nil else { continue }
                group.addTask { [downloads] in
                    await downloads.prefetch(key) { await Self.download(url, edge: pixelEdge) }
                }
                running += 1
            }
        }
    }

    /// Opens the artwork hosts' connections while YouTube builds Home, so its first art needn't.
    @concurrent
    public static func preconnect() async {
        await withTaskGroup(of: Void.self) { group in
            for host in ["lh3.googleusercontent.com", "i.ytimg.com"] {
                guard let url = URL(string: "https://\(host)/") else { continue }
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                request.httpMethod = "HEAD"
                group.addTask { _ = try? await HTTP.data(for: request, session: HTTP.media) }
            }
        }
    }

    /// Keeps `url`'s artwork on the phone until `keepOnly` lets it go, so it shows offline.
    @concurrent
    public func keep(_ url: String) async {
        let file = Self.keptFile(url)
        guard !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)),
              let request = Self.requestURL(url, edge: Self.playerEdge),
              let data = try? await HTTP.data(for: URLRequest(url: request), session: HTTP.media).0
        else { return }
        try? FileManager.default.createDirectory(at: Self.kept, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    @concurrent
    public func keepOnly(_ urls: Set<String>) async {
        let names = Set(urls.map { Self.keptFile($0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.kept, includingPropertiesForKeys: nil)) ?? []
        for file in files where !names.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func keptFile(_ url: String) -> URL {
        let name = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        return kept.appending(path: name)
    }

    /// Keyed by what is requested, so artwork stored at different sizes
    /// shares one decode and one download.
    static func key(_ url: String, _ edge: Int) -> String {
        "\(edge):\(isWide(url) ? url : Thumbnail.resized(url, edge: edge))"
    }

    @concurrent
    private static func fetch(_ url: String, edge: Int) async -> CGImage? {
        if let data = try? Data(contentsOf: keptFile(url)), let image = decode(data, edge: edge) {
            return image
        }
        guard let url = requestURL(url, edge: edge) else {
            log.debug("Skipped artwork from a host the app doesn't use.")
            return nil
        }
        var request = URLRequest(url: url)
        if let kept = inDateCopy(of: &request), let image = decode(kept, edge: edge) { return image }
        do {
            let (data, _) = try await HTTP.data(for: request, session: HTTP.media)
            try Task.checkCancellation()
            guard let image = decode(data, edge: edge) else {
                log.debug("Undecodable artwork.")
                // Only artwork that decodes is kept.
                HTTP.artworkCache.removeCachedResponse(for: request)
                return nil
            }
            return image
        } catch {
            return nil
        }
    }

    /// Fetches `url` at `edge` for the URL cache to keep, unless it already
    /// holds it. The bytes are dropped: `fetch` reads them back from the cache.
    @concurrent
    private static func download(_ url: String, edge: Int) async {
        guard !FileManager.default.fileExists(atPath: keptFile(url).path(percentEncoded: false)),
              var request = requestURL(url, edge: edge).map({ URLRequest(url: $0) }),
              inDateCopy(of: &request) == nil
        else { return }
        _ = try? await HTTP.data(for: request, session: HTTP.media)
    }

    /// The cached copy if under `maxAge` old; an older one is dropped and `request` set to skip the cache.
    private static func inDateCopy(of request: inout URLRequest) -> Data? {
        guard let cached = HTTP.artworkCache.cachedResponse(for: request) else { return nil }
        guard isStale(cached.response, now: .now) else { return cached.data }
        // Removed too, so no other request reads the old copy before the fresh one is stored.
        HTTP.artworkCache.removeCachedResponse(for: request)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return nil
    }

    /// By the date the server sent it; one without a date it can read counts as in date.
    static func isStale(_ response: URLResponse, now: Date) -> Bool {
        guard let sent = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Date"),
              let date = try? Date(sent, strategy: httpDate)
        else { return false }
        return now.timeIntervalSince(date) > maxAge
    }

    /// googleusercontent renders any size, so ask for the pixels drawn; a wide
    /// banner keeps the rendition it came with, as a square size would crop it.
    static func requestURL(_ url: String, edge: Int) -> URL? {
        guard isWide(url) else { return Thumbnail.url(url, edge: edge) }
        return URL(string: url).flatMap { HTTP.isAllowed($0) ? $0 : nil }
    }

    /// Whether a googleusercontent URL's size, as `=w1440-h600-p-l90-rj`,
    /// names a width and height that differ.
    static func isWide(_ url: String) -> Bool {
        guard url.contains("googleusercontent.com"), let eq = url.lastIndex(of: "=") else { return false }
        let size = url[url.index(after: eq)...].split(separator: "-", maxSplits: 2)
        guard size.count >= 2, size[0].first == "w", size[1].first == "h",
              let width = Int(size[0].dropFirst()), let height = Int(size[1].dropFirst())
        else { return false }
        return width != height
    }

    /// `data` decoded with its shorter side at most `edge` pixels, the
    /// orientation applied, and decoded now rather than on first draw.
    static func decode(_ data: Data, edge: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        // ImageIO bounds the longer side, while the view crops to fill, so
        // the shorter side is what has to reach the edge drawn. Never scaled up.
        let shorter = max(min(width, height), 1)
        let longer = max(width, height)
        let longest = shorter > edge ? (longer * edge + shorter - 1) / shorter : longer
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(longest, 1),
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
