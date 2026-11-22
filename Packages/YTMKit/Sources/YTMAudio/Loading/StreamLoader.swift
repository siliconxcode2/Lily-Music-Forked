import Foundation
import os

/// Asks in ranges, as googlevideo throttles large ones, and on a refusal carries on from
/// the same byte at a fresh URL for the same file. The ranges follow `readPosition`, so a seek
/// ahead is fetched next and the gaps after.
final class StreamLoader {
    static let rangeLength: Int64 = 1 << 20
    private static let maxRetries = 4
    static let retryDelay = Duration.milliseconds(500)
    static let maxRetryDelay = Duration.seconds(5)
    /// How long a connection that stops answering is retried, so one that comes back within it plays on.
    static let rideOut = Duration.seconds(60)
    /// Fresh URLs asked for in a row without a whole range arriving: one per plain-URL client in YTMCore,
    /// which this module can't see; StreamRecoveryTests keeps the two in step.
    static let maxRefreshes = 3
    private static let replayLength: Int64 = 256 << 10
    static let warmLength: Int64 = 64 << 10

    /// Its descriptor follows the file as a finished part becomes the cached file.
    let reader: FileHandle
    /// Where the reader wants bytes from, which the download fetches first: 0, or a seek point
    /// past the bytes held from the start.
    var readPosition: Int64 = 0
    private var held: HeldBlocks
    private(set) var isComplete: Bool
    private let item: AudioItem
    private let cache: AudioCache
    private var url: URL
    /// The headers of the client that gave `url`, as googlevideo checks them.
    private var headers: [String: String]
    private var writer: FileHandle?
    private var part: URL?

    init(item: AudioItem, cache: AudioCache) throws(AudioFailure) {
        self.item = item
        self.cache = cache
        url = item.url
        headers = item.headers
        do {
            // A downloaded song plays from its own file, which the cache never holds.
            if let file = item.url.isFileURL ? item.url : cache.completeFile(for: item.cacheKey, length: item.contentLength) {
                reader = try FileHandle(forReadingFrom: file)
                held = HeldBlocks(total: try Int64(reader.seekToEnd()))
                held.put(at: 0, count: held.total)
                isComplete = true
            } else {
                let part = try cache.makePart(for: item.cacheKey)
                self.part = part
                writer = try FileHandle(forWritingTo: part)
                reader = try FileHandle(forReadingFrom: part)
                held = HeldBlocks(total: max(item.contentLength, 0))
                isComplete = false
            }
        } catch {
            throw .storage
        }
        if !item.url.isFileURL { cache.hold(item.cacheKey) }
    }

    deinit {
        if let part, !isComplete {
            cache.discard(part)
        }
        if !item.url.isFileURL { cache.release(item.cacheKey) }
    }

    /// The file's length, or 0 until a download of unknown length ends.
    var total: Int64 { held.total }
    /// Bytes on disk from the start of the file.
    var available: Int64 { held.runEnd(from: 0) }

    /// The end of the bytes on disk unbroken from `offset`.
    func runEnd(from offset: Int64) -> Int64 {
        held.runEnd(from: offset)
    }

    /// Returns why it failed, or nil once complete or cancelled. `onBytes` gets every byte once, in order
    /// from the start; `onElsewhere` follows each piece that lands past them.
    func run(
        isolation: isolated (any Actor)? = #isolation,
        source: any ByteSource,
        onBytes: (Data) -> Void,
        onElsewhere: () -> Void = {}
    ) async -> AudioFailure? {
        if isComplete {
            return await replay(from: 0, upTo: total, onBytes)
        }
        // The start `warm` fetched, and any blocks a run cut short left, are on disk already.
        var delivered = available
        if delivered > 0, let failure = await replay(from: 0, upTo: delivered, onBytes) {
            return failure
        }
        var retries = 0
        // Kept apart, so a stray error once a lost connection is back gets its own tries.
        var drops = 0
        var refreshes = 0
        // From the first failure in a row, not the last byte: a phone back from a dead zone fails at once.
        var failingSince: ContinuousClock.Instant?
        // The range after the one arriving, asked for already so it follows with no round trip.
        var ahead: (start: Int64, bytes: AsyncThrowingStream<Data, any Error>)?
        while total <= 0 || available < total {
            guard !Task.isCancelled else { return nil }
            guard let start = held.nextRange(readingAt: readPosition) else { break }
            let end = Self.rangeEnd(from: start, total: total)
            let bytes = if let ahead, ahead.start == start {
                ahead.bytes
            } else {
                source.bytes(of: url, headers: headers, range: start..<end)
            }
            ahead = nil
            if end < total {
                // Dropped next time round should the reader have moved by then.
                var after = held
                after.put(at: start, count: end - start)
                ahead = after.nextRange(readingAt: readPosition).map { next in
                    (next, source.bytes(of: url, headers: headers, range: next..<Self.rangeEnd(from: next, total: total)))
                }
            }
            do {
                var at = start
                for try await data in bytes {
                    guard !Task.isCancelled else { return nil }
                    // Never past the range, as the block after it may be held already.
                    let piece = Int64(data.count) > end - at ? data.prefix(Int(end - at)) : data
                    try write(piece, at: at)
                    if at == delivered {
                        onBytes(piece)
                        delivered += Int64(piece.count)
                    } else {
                        onElsewhere()
                    }
                    at += Int64(piece.count)
                    // A range that reaches blocks held already joins them to the bytes from the start.
                    if available > delivered {
                        if let failure = await replay(from: delivered, upTo: available, onBytes) {
                            return failure
                        }
                        delivered = available
                    }
                    if at == end {
                        break
                    }
                }
                guard !Task.isCancelled else { return nil }
                guard at > start else { throw ByteSourceError.empty }
                if end == .max {
                    held.total = at
                }
                retries = 0
                drops = 0
                refreshes = 0
                failingSince = nil
            } catch {
                ahead = nil
                guard !Task.isCancelled else { return nil }
                if let failure = error as? AudioFailure {
                    return failure
                }
                // A range that broke off after some bytes still got somewhere,
                // so only a stretch with nothing arriving gives up.
                if held.runEnd(from: start) > start {
                    retries = 0
                    drops = 0
                    failingSince = nil
                }
                if error as? ByteSourceError == .refused {
                    guard refreshes < Self.maxRefreshes, let fresh = await refreshed(again: refreshes > 0) else { return .refused }
                    refreshes += 1
                    url = fresh.url
                    headers = fresh.headers
                    continue
                }
                if Self.isConnection(error) {
                    let since = failingSince ?? .now
                    failingSince = since
                    guard let delay = Self.rideOutDelay(drops: drops, failingFor: .now - since) else {
                        Logger.audio.warning("A download lost its connection for good: \(Self.reason(error), privacy: .public)")
                        return .dropped
                    }
                    drops += 1
                    Logger.audio.debug("Download lost its connection, retry \(drops): \(Self.reason(error), privacy: .public)")
                    try? await Task.sleep(for: delay)
                    continue
                }
                guard retries < Self.maxRetries else {
                    Logger.audio.warning("A download failed after \(Self.maxRetries) retries: \(Self.reason(error), privacy: .public)")
                    return .download
                }
                retries += 1
                Logger.audio.debug("Download range failed, retry \(retries): \(Self.reason(error), privacy: .public)")
                try? await Task.sleep(for: Self.retryDelay * retries)
            }
        }
        try? writer?.close()
        writer = nil
        if let part {
            cache.commit(part, as: item.cacheKey)
        }
        isComplete = true
        return nil
    }

    /// Ends on a megabyte, as a cut-off URL serves the first and refuses the rest, so the range after a warm-up's
    /// start must not run past it. A file of unknown length is asked for to its end.
    static func rangeEnd(from start: Int64, total: Int64) -> Int64 {
        total > 0 ? min((start / rangeLength + 1) * rangeLength, total) : .max
    }

    /// Only a head start for `run`, so it never retries.
    func warm(isolation: isolated (any Actor)? = #isolation, source: any ByteSource) async {
        guard available == 0, total > 0 else { return }
        do {
            for try await data in source.bytes(of: url, headers: headers, range: 0..<min(Self.warmLength, total)) {
                guard !Task.isCancelled else { return }
                try write(data, at: available)
                // A whole file answered in place of the range is too much for a warm-up.
                guard available < Self.warmLength else { return }
            }
        } catch {
            Logger.audio.debug("Could not warm a stream")
        }
    }

    /// Bytes that fail to be written are not counted, so a later range writes them again.
    private func write(_ data: Data, at offset: Int64) throws(AudioFailure) {
        guard let writer else { return }
        do {
            try writer.seek(toOffset: UInt64(offset))
            try writer.write(contentsOf: data)
        } catch {
            throw .storage
        }
        held.put(at: offset, count: Int64(data.count))
    }

    /// Bytes on disk, read without moving `reader`, which a replay may be part way through.
    func bytes(at offset: Int64, count: Int) -> Data? {
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { pread(reader.fileDescriptor, $0.baseAddress, count, off_t(offset)) }
        return read == count ? data : nil
    }

    /// Yields between pieces so commands can run.
    private func replay(
        isolation: isolated (any Actor)? = #isolation, from start: Int64, upTo end: Int64, _ onBytes: (Data) -> Void
    ) async -> AudioFailure? {
        // A loader kept from a download cut short left its reader where that
        // replay stopped: the decoder reads with pread, which never moves it.
        guard (try? reader.seek(toOffset: UInt64(start))) != nil else { return .damaged }
        var offset = start
        while offset < end {
            guard !Task.isCancelled else { return nil }
            guard let data = try? reader.read(upToCount: Int(min(Self.replayLength, end - offset))), !data.isEmpty else {
                return .damaged
            }
            onBytes(data)
            offset += Int64(data.count)
            await Task.yield()
        }
        return nil
    }

    /// Taken only if it serves the same encode, as the bytes already held must line up.
    private func refreshed(
        isolation: isolated (any Actor)? = #isolation, again: Bool
    ) async -> (url: URL, headers: [String: String])? {
        do {
            let fresh = try await item.refresh(again)
            guard Self.sameFile(url, fresh.url) else {
                Logger.audio.warning("A refreshed stream URL serves a different file")
                return nil
            }
            return fresh
        } catch {
            Logger.audio.warning("No fresh URL for a refused download")
            return nil
        }
    }

    /// The same format, of the same length, from the same encode.
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let first = parameters(a)
        let second = parameters(b)
        return first["itag"] != nil && ["itag", "clen", "lmt"].allSatisfy { first[$0] == second[$0] }
    }

    /// The wait before retrying after `drops` lost connections in a row, doubling, or nil once
    /// they have gone on for `rideOut`.
    static func rideOutDelay(drops: Int, failingFor: Duration) -> Duration? {
        failingFor < rideOut ? min(retryDelay * (1 << min(drops, 16)), maxRetryDelay) : nil
    }

    /// Whether the connection failed, rather than googlevideo answering with an error or bytes
    /// that don't fit: URLSession reports an answer's status through `ByteSourceError`.
    static func isConnection(_ error: any Error) -> Bool {
        (error as? URLError).map { $0.code != .cancelled } ?? false
    }

    /// Why a range failed, without the error itself: a URLError's
    /// description carries the stream URL.
    private static func reason(_ error: any Error) -> String {
        switch error {
        case let error as ByteSourceError: String(describing: error)
        case let error as URLError: "URLError \(error.code.rawValue)"
        default: "other"
        }
    }

    private static func parameters(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }
}

extension Logger {
    static let audio = Logger(subsystem: "Lily", category: "audio")
}
