import Foundation
import Synchronization
import Testing
@testable import YTMAudio

struct StreamLoaderTests {
    private let file = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    private let cache = AudioCache(.init(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), limit: 1 << 20))

    private func load(_ item: AudioItem, from source: any ByteSource) async throws -> (StreamLoader, Data, AudioFailure?) {
        let loader = try StreamLoader(item: item, cache: cache)
        var received = Data()
        let failure = await loader.run(source: source) { received.append($0) }
        return (loader, received, failure)
    }

    @Test func resumesOnlyOnTheSameFile() throws {
        let url = try #require(URL(string: "https://rr1.googlevideo.com/videoplayback?expire=1&itag=251&clen=4171552&lmt=1700000000000000&n=a"))
        let fresh = "https://rr4.googlevideo.com/videoplayback?itag=251&n=b&lmt=1700000000000000&clen=4171552"
        func same(_ other: String) throws -> Bool { StreamLoader.sameFile(url, try #require(URL(string: other))) }
        #expect(try same(fresh), "another host and order, same file")
        #expect(try !same(fresh.replacingOccurrences(of: "itag=251", with: "itag=250")))
        #expect(try !same(fresh.replacingOccurrences(of: "clen=4171552", with: "clen=4171553")))
        #expect(try !same(fresh.replacingOccurrences(of: "lmt=1700000000000000", with: "lmt=1")), "re-encoded")
        let bare = try #require(URL(string: "https://a/251"))
        #expect(!StreamLoader.sameFile(bare, bare), "no format to go by")
    }

    @Test func carriesOnFromTheSameByteAtAFreshURL() async throws {
        let item = try AudioItem.fixture("song", length: file.count)
        let (loader, received, failure) = try await load(item, from: RefusingPartWay(files: ["song": file], after: 3_000))
        #expect(failure == nil && received == file && loader.isComplete)
        let cached = try #require(cache.completeFile(for: item.cacheKey, length: Int64(file.count)))
        #expect(try Data(contentsOf: cached) == file)
    }

    @Test func asksAFreshURLWithItsOwnClientsHeaders() async throws {
        let query = "itag=251&clen=\(file.count)&lmt=1&file=song"
        let stale = try #require(URL(string: "https://rr1.googlevideo.com/videoplayback?\(query)"))
        let fresh = try #require(URL(string: "https://rr2.googlevideo.com/videoplayback?\(query)&n=fresh"))
        let item = AudioItem(id: "x", url: stale, headers: ["User-Agent": "old"], contentLength: Int64(file.count),
                             cacheKey: "x-\(UUID())", loudnessDB: 0) { _ in
            (url: fresh, headers: ["User-Agent": "new"])
        }
        let source = AgentRecording(RefusingPartWay(files: ["song": file], after: 3_000))
        let (_, received, failure) = try await load(item, from: source)
        #expect(failure == nil && received == file)
        #expect(source.agents == ["old", "new"], "the rest is asked for as the fresh URL's client")
    }

    @Test func givesUpWhenEveryURLIsRefused() async throws {
        let stale = try #require(URL(string: "https://rr1.googlevideo.com/videoplayback?itag=251&clen=10000&lmt=1"))
        let asked = Asked()
        let item = AudioItem(id: "x", url: stale, headers: [:], contentLength: 10_000, cacheKey: "x-\(UUID())", loudnessDB: 0) { again in
            asked.again.withLock { $0.append(again) }
            return (url: stale, headers: [:])
        }
        let (loader, received, failure) = try await load(item, from: MemoryByteSource(files: [:], refuseFrom: 0))
        #expect(failure == .refused && received.isEmpty && !loader.isComplete)
        #expect(asked.again.withLock { $0 } == [false, true, true], "the same client once more, then each of the others")
    }

    @Test func refusesAFreshURLForAnotherFile() async throws {
        let stale = try #require(URL(string: "https://rr1.googlevideo.com/videoplayback?itag=251&clen=10000&lmt=1"))
        let other = try #require(URL(string: "https://rr1.googlevideo.com/videoplayback?itag=251&clen=10000&lmt=2&n=fresh"))
        let item = AudioItem(id: "x", url: stale, headers: [:], contentLength: 10_000, cacheKey: "x-\(UUID())", loudnessDB: 0) { _ in
            (url: other, headers: [:])
        }
        let (_, _, failure) = try await load(item, from: MemoryByteSource(files: [:], refuseFrom: 0))
        #expect(failure == .refused)
    }

    @Test func playsACachedFileWithNoNetwork() async throws {
        let item = try AudioItem.fixture("song", length: file.count)
        _ = try await load(item, from: MemoryByteSource(files: ["song": file]))
        let again = AudioItem(id: "again", url: item.url, headers: [:], contentLength: item.contentLength,
                              cacheKey: item.cacheKey, loudnessDB: 0, refresh: item.refresh)
        let (loader, received, failure) = try await load(again, from: MemoryByteSource(files: [:], refuseFrom: 0))
        #expect(failure == nil && received == file && loader.isComplete && loader.available == Int64(file.count))
    }

    @Test func fetchesTheReadPositionFirstAndHandsOnBytesInOrder() async throws {
        let megabyte = StreamLoader.rangeLength
        let file = Data((0..<Int(5 * megabyte + 100)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let item = try AudioItem.fixture("song", length: file.count)
        let source = RecordingByteSource(files: ["song": file])
        // Past this suite's cap, which must not evict the file it has just finished.
        let loader = try StreamLoader(item: item, cache: cache)
        loader.readPosition = 3 * megabyte + 10
        var received = Data()
        var elsewhere = 0
        let failure = await loader.run(source: source) { received.append($0) } onElsewhere: {
            elsewhere += 1
        }
        let ranges = [3, 4, 5, 0, 1, 2].map { $0 * megabyte..<min(($0 + 1) * megabyte, Int64(file.count)) }
        #expect(failure == nil && source.ranges == ranges, "the read position's block on to the end, then the gap")
        #expect(received == file && elsewhere > 0, "the bytes past the gap wait for it")
        let cached = try #require(cache.completeFile(for: item.cacheKey, length: Int64(file.count)))
        #expect(try Data(contentsOf: cached) == file)
    }

    @Test func keepsTheFileItPlaysPastTheCap() async throws {
        let cache = AudioCache(.init(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), limit: 15_000))
        let source = MemoryByteSource(files: ["a": file, "b": file, "c": file])
        let (a, b, c) = try (AudioItem.fixture("a", length: file.count), AudioItem.fixture("b", length: file.count),
                             AudioItem.fixture("c", length: file.count))
        var playing: StreamLoader? = try StreamLoader(item: a, cache: cache)
        _ = await playing?.run(source: source) { _ in }
        _ = try await StreamLoader(item: b, cache: cache).run(source: source) { _ in }
        #expect(cache.completeFile(for: a.cacheKey, length: Int64(file.count)) != nil, "still playing")
        playing = nil
        _ = try await StreamLoader(item: c, cache: cache).run(source: source) { _ in }
        #expect(cache.completeFile(for: a.cacheKey, length: Int64(file.count)) == nil)
    }

    @Test func rangesEndOnAMegabyte() {
        #expect(StreamLoader.rangeEnd(from: 65_536, total: 4_171_552) == 1_048_576, "the range after a warm-up")
        #expect(StreamLoader.rangeEnd(from: 1_048_576, total: 4_171_552) == 2_097_152)
        #expect(StreamLoader.rangeEnd(from: 4_000_000, total: 4_171_552) == 4_171_552)
        #expect(StreamLoader.rangeEnd(from: 0, total: 0) == .max, "of unknown length")
    }

    @Test func retriesADroppedConnectionUntilItHasBeenGoneAWhile() {
        #expect(StreamLoader.rideOutDelay(drops: 0, failingFor: .zero) == StreamLoader.retryDelay)
        #expect(StreamLoader.rideOutDelay(drops: 1, failingFor: .seconds(1)) == StreamLoader.retryDelay * 2)
        #expect(StreamLoader.rideOutDelay(drops: 40, failingFor: .seconds(30)) == StreamLoader.maxRetryDelay, "capped")
        #expect(StreamLoader.rideOutDelay(drops: 0, failingFor: StreamLoader.rideOut) == nil, "given up")
    }

    @Test func tellsLostConnectionsFromOtherErrors() {
        #expect(StreamLoader.isConnection(URLError(.networkConnectionLost)))
        #expect(StreamLoader.isConnection(URLError(.notConnectedToInternet)))
        #expect(!StreamLoader.isConnection(URLError(.cancelled)))
        #expect(!StreamLoader.isConnection(ByteSourceError.status(503)), "an answer, not a lost connection")
        #expect(!StreamLoader.isConnection(ByteSourceError.refused))
        #expect(!StreamLoader.isConnection(ByteSourceError.empty))
    }

    @Test func carriesOnOnceTheConnectionIsBack() async throws {
        let item = try AudioItem.fixture("song", length: file.count)
        let (_, received, failure) = try await load(item, from: DroppingOnce(file: file))
        #expect(failure == nil && received == file)
    }

    @Test func warmsOnlyTheStartOfAWholeFileAnswer() async throws {
        let whole = Data(count: 200_000)
        let item = try AudioItem.fixture("song", length: whole.count)
        let loader = try StreamLoader(item: item, cache: cache)
        await loader.warm(source: IgnoringRanges(file: whole))
        #expect(loader.available == StreamLoader.warmLength)
    }
}

/// Answers any range with the whole file, as a server ignoring ranges does.
private struct IgnoringRanges: ByteSource {
    let file: Data

    func bytes(of url: URL, headers: [String: String], range: Range<Int64>) -> AsyncThrowingStream<Data, any Error> {
        MemoryByteSource(files: ["song": file]).bytes(of: url, headers: headers, range: 0..<Int64(file.count))
    }
}

/// Whether each refresh was told the last fresh URL was refused too.
private final class Asked: Sendable {
    let again = Mutex<[Bool]>([])
}

/// Loses the connection on the first request, then serves the file.
private final class DroppingOnce: ByteSource {
    private let file: Data
    private let dropped = Mutex(false)

    init(file: Data) {
        self.file = file
    }

    func bytes(of url: URL, headers: [String: String], range: Range<Int64>) -> AsyncThrowingStream<Data, any Error> {
        let first = dropped.withLock { dropped in
            defer { dropped = true }
            return !dropped
        }
        if first {
            return AsyncThrowingStream { $0.finish(throwing: URLError(.networkConnectionLost)) }
        }
        return MemoryByteSource(files: ["song": file]).bytes(of: url, headers: headers, range: range)
    }
}

private final class AgentRecording: ByteSource {
    private let served: any ByteSource
    private let asked = Mutex<[String]>([])

    init(_ served: any ByteSource) {
        self.served = served
    }

    var agents: [String] { asked.withLock { $0 } }

    func bytes(of url: URL, headers: [String: String], range: Range<Int64>) -> AsyncThrowingStream<Data, any Error> {
        asked.withLock { $0.append(headers["User-Agent"] ?? "") }
        return served.bytes(of: url, headers: headers, range: range)
    }
}

/// Refuses a stale URL part way through a range, as googlevideo sometimes
/// does once the first megabyte or so has come; a fresh URL serves it all.
private struct RefusingPartWay: ByteSource {
    let files: [String: Data]
    let after: Int64

    func bytes(of url: URL, headers: [String: String], range: Range<Int64>) -> AsyncThrowingStream<Data, any Error> {
        let served = MemoryByteSource(files: files, piece: 1_000).bytes(of: url, headers: headers, range: range)
        guard !url.absoluteString.contains("fresh") else { return served }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var offset = range.lowerBound
                do {
                    for try await data in served {
                        guard offset + Int64(data.count) <= after else { throw ByteSourceError.refused }
                        continuation.yield(data)
                        offset += Int64(data.count)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
