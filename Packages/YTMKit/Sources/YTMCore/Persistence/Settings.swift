import Foundation

public enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off, all, one
}

/// Smart shuffle mixes recommended songs in; it is a kind of shuffle, so it
/// goes off with it.
public enum ShuffleMode: String, Codable, CaseIterable, Sendable {
    case off, on, smart
}

/// How tracks are evened out: Normal to YouTube's reference loudness, Quiet 6 dB under it, as Spotify's Quiet
/// sits under its Normal.
public enum Normalise: String, Codable, CaseIterable, Sendable {
    case off, quiet, normal
}

public enum Look: String, Codable, CaseIterable, Sendable {
    case dark, light, black
}

/// The colour of active controls, in the order Settings offers them.
public enum Accent: String, Codable, CaseIterable, Sendable {
    case lily, red, orange, green, teal, blue, purple, pink, artwork

    /// As `0xRRGGBB`, or nil for the artwork's, which changes with the song.
    public var rgb: UInt32? {
        switch self {
        case .lily: 0xd65db1  // The orchid of Lily's icon
        case .red: 0xff0033  // YouTube Music's red
        case .orange: 0xff6a13
        case .green: 0x1db954
        case .teal: 0x00a89d
        case .blue: 0x3d7bff
        case .purple: 0x9b5cff
        case .pink: 0xf0458f
        case .artwork: nil
        }
    }

    public var name: String {
        switch self {
        case .lily: "Lily"
        case .red: "Red"
        case .orange: "Orange"
        case .green: "Green"
        case .teal: "Teal"
        case .blue: "Blue"
        case .purple: "Purple"
        case .pink: "Pink"
        case .artwork: "From the artwork"
        }
    }
}

public struct Settings: Codable, Equatable, Sendable {
    /// YTMCore cannot see YTMAudio's EqualiserBands, so its bands are repeated here and checked by a test.
    static let equaliserFrequencies: [Float] = [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    /// In the order Settings offers them.
    public static let speeds = [0.8, 0.9, 1.0, 1.1, 1.2, 1.3]
    /// The crossfade lengths Settings offers, in seconds.
    public static let crossfadeLengths: [Double] = [1, 2, 3, 4, 5, 6, 8, 10, 12]

    public var muted = false
    public var quality: AudioQuality = .high
    public var normalise: Normalise = .normal
    /// Fade each track into the next, rather than playing them gaplessly.
    public var crossfade = false
    /// Long enough to blend two songs, short enough to keep most of an ending.
    public var crossfadeSeconds = 6.0
    /// Pauses as the device playing is unplugged, rather than carrying on through the next.
    public var pauseOnUnplug = true
    public var speed = 1.0
    public var autoplay = true
    public var shuffle: ShuffleMode = .off
    public var repeatMode: RepeatMode = .off
    public var equaliserEnabled = false
    /// Each band's gain in dB, kept while the equaliser is off.
    public var equaliserGains: [Float] = Array(repeating: 0, count: Settings.equaliserFrequencies.count)
    public var crossfeed = false
    public var mono = false
    /// From -1, the left side alone, to 1, the right.
    public var balance: Float = 0
    /// Report songs played to the signed-in account's YouTube history.
    public var youtubeHistory = true
    public var ratingButtons = true
    public var look: Look = .black
    public var accent: Accent = .lily
    /// The account has been served Premium formats, so songs without them (music videos) never mark it as not Premium.
    public var premiumAccount = false
    /// The account was taken as without Premium: songs start on the free stream while a background check confirms it.
    public var noPremium = false
    public var downloadQuality: AudioQuality = .high
    /// Downloads wait for a network that isn't metered, as cellular and hotspots are.
    public var downloadOnWiFiOnly = true
    /// Keeps a pick of the songs this phone plays downloaded, picked afresh each day.
    public var smartDownloads = false
    public var smartDownloadCount = 50
    /// On iPhone Duo, folding the half-open hinge skips back and opening it skips ahead.
    public var foldToScrub = false
    /// The signed-in account as last loaded, its name and picture shown at once on the next start.
    public var account: Account?
    /// Playlist IDs pinned to the top of Library's playlists, first pinned first.
    public var pinned: [String] = []

    public init() {}

    /// Reads each setting on its own, so an unreadable one resets alone rather
    /// than taking an opt-out such as `youtubeHistory` with it.
    public init(from decoder: any Decoder) throws {
        self.init()
        let file = try decoder.container(keyedBy: CodingKeys.self)
        file.read(&muted, .muted)
        file.read(&quality, .quality)
        file.read(&normalise, .normalise)
        // Older versions kept it as on or off, which is Normal or Off.
        if let on = try? file.decodeIfPresent(Bool.self, forKey: .normalise) {
            normalise = on ? .normal : .off
        }
        file.read(&crossfade, .crossfade)
        file.read(&crossfadeSeconds, .crossfadeSeconds)
        // Outside the lengths offered, the nearer end of them.
        crossfadeSeconds = min(max(crossfadeSeconds, Self.crossfadeLengths[0]), Self.crossfadeLengths[Self.crossfadeLengths.count - 1])
        file.read(&pauseOnUnplug, .pauseOnUnplug)
        file.read(&speed, .speed) { Self.speeds.contains($0) }
        file.read(&autoplay, .autoplay)
        file.read(&shuffle, .shuffle)
        file.read(&repeatMode, .repeatMode)
        file.read(&equaliserEnabled, .equaliserEnabled)
        if let gains = try? file.decodeIfPresent([Float].self, forKey: .equaliserGains), let gains = Self.equaliserGains(gains) {
            equaliserGains = gains
        }
        file.read(&crossfeed, .crossfeed)
        file.read(&mono, .mono)
        file.read(&balance, .balance)
        balance = min(max(balance, -1), 1)
        file.read(&youtubeHistory, .youtubeHistory)
        file.read(&ratingButtons, .ratingButtons)
        file.read(&look, .look)
        file.read(&accent, .accent)
        file.read(&premiumAccount, .premiumAccount)
        file.read(&noPremium, .noPremium)
        file.read(&downloadQuality, .downloadQuality)
        file.read(&downloadOnWiFiOnly, .downloadOnWiFiOnly)
        file.read(&smartDownloads, .smartDownloads)
        file.read(&smartDownloadCount, .smartDownloadCount) { $0 > 0 }
        file.read(&foldToScrub, .foldToScrub)
        file.read(&account, .account)
        file.read(&pinned, .pinned)
    }

    /// Older versions had six bands, which are carried over to the ten by interpolating in log-frequency between
    /// their centres, to the whole dB the sliders step in, so the old presets land on the new ones. Nil for any
    /// other count.
    static func equaliserGains(_ gains: [Float]) -> [Float]? {
        if gains.count == equaliserFrequencies.count { return gains }
        let old: [Double] = [60, 150, 400, 1_000, 2_400, 15_000]
        guard gains.count == old.count else { return nil }
        return equaliserFrequencies.map { centre in
            let hz = Double(centre)
            let db: Float = switch old.count(where: { $0 <= hz }) {
            case 0: gains[0]
            case old.count: gains[old.count - 1]
            case let i:
                gains[i - 1] + (gains[i] - gains[i - 1]) * Float(log(hz / old[i - 1]) / log(old[i] / old[i - 1]))
            }
            // Adding 0 turns a rounded -0 into 0.
            return db.rounded() + 0
        }
    }
}

extension KeyedDecodingContainer {
    /// Overwrites `value` with the key's when present, readable and `valid`.
    func read<T: Decodable>(_ value: inout T, _ key: Key, valid: (T) -> Bool = { _ in true }) {
        if let decoded = try? decodeIfPresent(T.self, forKey: key), valid(decoded) {
            value = decoded
        }
    }
}
