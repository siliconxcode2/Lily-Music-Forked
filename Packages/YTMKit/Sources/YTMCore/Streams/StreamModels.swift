import Foundation

/// Low and Normal cap the bitrate for metered connections; High takes the
/// best YouTube offers, 256 kbps Opus with Premium.
public enum AudioQuality: String, Codable, CaseIterable, Hashable, Sendable {
    case low, normal, high

    /// The highest bitrate wanted, or nil for the best there is. YouTube's
    /// Opus streams come at about 50, 70 and 130 kbps.
    public var maxKbps: Int? {
        switch self {
        case .low: 64
        case .normal: 192
        case .high: nil
        }
    }
}

public enum AudioCodec: String, Codable, Hashable, Sendable {
    /// In WebM, 48 kHz.
    case opus
    /// AAC-LC or HE-AAC in fragmented MP4.
    case aac
}

public struct ResolvedStream: Codable, Hashable, Sendable {
    public var url: URL
    /// Headers the download must send, as the client that asked.
    public var headers: [String: String]
    public var itag: Int
    public var codec: AudioCodec
    public var contentLength: Int64
    public var bitrate: Int
    public var duration: Double?
    /// YouTube's loudness measure in dB, for normalising.
    public var loudnessDb: Double?
    /// A Premium format (774 or 141). Free formats the web client gives a
    /// Premium account are not.
    public var isPremium: Bool
    /// The plain-URL client it came from, if one, so a refresh it refuses too can ask it last.
    public var client: String?

    public init(
        url: URL, headers: [String: String], itag: Int, codec: AudioCodec,
        contentLength: Int64, bitrate: Int, duration: Double?, loudnessDb: Double?,
        isPremium: Bool = false
    ) {
        self.url = url
        self.headers = headers
        self.itag = itag
        self.codec = codec
        self.contentLength = contentLength
        self.bitrate = bitrate
        self.duration = duration
        self.loudnessDb = loudnessDb
        self.isPremium = isPremium
    }

    /// "OPUS 165", with Premium formats at YouTube's nominal 256 kbps.
    public var badge: String {
        let kbps = PremiumResolver.premiumItags.contains(itag) ? 256 : (bitrate + 500) / 1000
        return "\(codec.rawValue.uppercased()) \(kbps)"
    }
}
