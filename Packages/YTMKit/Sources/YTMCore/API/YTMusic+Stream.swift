import Foundation

extension YTMusic {
    /// The free path: plain-URL clients, best_audio within the quality's cap (Opus first, AAC after).
    /// With `itag`, that format only, so a download can carry on from another client's URL.
    @concurrent
    public func stream(videoId: String, quality: AudioQuality, itag: Int? = nil) async throws -> ResolvedStream {
        try await StreamResolver(innerTube: innerTube).resolve(videoId: videoId, maxKbps: quality.maxKbps, itag: itag)
    }

    /// Asks `client`'s streams last for the rest of the session, as googlevideo cuts them off here.
    public func cutOffStreams(of client: String) {
        StreamResolver.cutOff(client: client)
    }
}
