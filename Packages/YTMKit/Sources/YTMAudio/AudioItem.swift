import Foundation

public struct AudioItem: Sendable {
    /// Stable for one entry of the queue, so events name the entry they concern.
    public let id: String
    public let url: URL
    public let headers: [String: String]
    /// 0 when the server did not say.
    public let contentLength: Int64
    /// Names the file in the disk cache, so the same encode plays from there next time.
    public let cacheKey: String
    /// The correction to the reference loudness, turning down or up, applied only while the player normalises.
    public let loudnessDB: Float
    /// A fresh URL and headers for the same file, asked for when the old URL is refused part way through.
    /// Told whether the last fresh URL was refused too.
    public let refresh: @Sendable (_ again: Bool) async throws -> (url: URL, headers: [String: String])

    public init(
        id: String,
        url: URL,
        headers: [String: String],
        contentLength: Int64,
        cacheKey: String,
        loudnessDB: Float,
        refresh: @escaping @Sendable (_ again: Bool) async throws -> (url: URL, headers: [String: String])
    ) {
        self.id = id
        self.url = url
        self.headers = headers
        self.contentLength = contentLength
        self.cacheKey = cacheKey
        self.loudnessDB = loudnessDB
        self.refresh = refresh
    }

    var loudnessGain: Float { pow(10, loudnessDB / 20) }
}

public enum AudioEvent: Sendable, Equatable {
    /// The first sound of an item started by `play`.
    case started(id: String)
    /// The next item became the one heard, with no gap or as a crossfade began.
    case advanced(id: String)
    /// The last item ended with nothing queued after it.
    case finished
    /// The item could not play. For the item queued by `setNext`, it was dropped
    /// and the current one ends with `finished`, so the next loads afresh.
    case failed(id: String, message: String)
    /// The item's download gave up on a connection that stopped answering; for the item
    /// queued by `setNext`, it was dropped as for `failed`.
    case dropped(id: String)
    case buffering(Bool)
    /// A seek in the current item dropped the next one, which had already
    /// started following it; queue it again with `setNext`.
    case nextDropped
}
