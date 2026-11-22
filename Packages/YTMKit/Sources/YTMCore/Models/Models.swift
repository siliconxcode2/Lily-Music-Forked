import Foundation

// Every model is Sendable and Codable: it crosses actors and is saved as is
// (session, history, the cached Home feed).

public struct ArtistRef: Codable, Hashable, Sendable {
    public var id: String?
    public var name: String

    public init(id: String?, name: String) {
        self.id = id
        self.name = name
    }
}

public struct AlbumRef: Codable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct Track: Codable, Hashable, Sendable, Identifiable {
    /// The video ID.
    public var id: String
    public var title: String
    public var artists: [ArtistRef]
    public var album: AlbumRef?
    /// Length in seconds, when YouTube said.
    public var duration: Int?
    public var thumbnail: String?
    public var trackNumber: Int?
    /// A music video, which may have an audio-only song version YouTube Music
    /// plays instead.
    public var isVideo: Bool
    /// The entry's own ID in the account's playlist it was read from, which removing or moving it takes. Never
    /// saved, as it means nothing away from that playlist's page.
    public var setVideoId: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, artists, album, duration, thumbnail, trackNumber, isVideo
    }

    public init(
        id: String, title: String, artists: [ArtistRef] = [], album: AlbumRef? = nil,
        duration: Int? = nil, thumbnail: String? = nil, trackNumber: Int? = nil,
        isVideo: Bool = false
    ) {
        self.id = id
        self.title = title
        self.artists = artists
        self.album = album
        self.duration = duration
        self.thumbnail = thumbnail
        self.trackNumber = trackNumber
        self.isVideo = isVideo
    }

    public var artistNames: String { ArtistRef.joined(artists) }
    public var firstArtistId: String? { artists.lazy.compactMap(\.id).first }
    public var seconds: Double { Double(duration ?? 0) }
}

extension ArtistRef {
    public static func joined(_ artists: [ArtistRef]) -> String {
        artists.lazy.map(\.name).joined(separator: ", ")
    }
}

public enum CardKind: String, Codable, Hashable, Sendable {
    case album, playlist, artist, genre
    /// A single song, played with a radio after it.
    case song
}

public struct Card: Codable, Hashable, Sendable, Identifiable {
    public var kind: CardKind
    /// Browse ID of an album or artist, playlist ID, genre params, or the
    /// video ID of a song.
    public var id: String
    public var title: String
    public var subtitle: String
    public var thumbnail: String?
    /// Genre chips carry YouTube's colour for them, as 0xRRGGBB.
    public var color: UInt32?
    /// The song a song card plays.
    public var track: Track?

    public init(
        kind: CardKind, id: String, title: String, subtitle: String = "",
        thumbnail: String? = nil, color: UInt32? = nil, track: Track? = nil
    ) {
        self.kind = kind
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.thumbnail = thumbnail
        self.color = color
        self.track = track
    }

    /// The page the card opens, if it opens one rather than playing.
    public var route: Route? {
        switch kind {
        case .album: .album(id)
        case .playlist: .playlist(id)
        case .artist: .artist(id)
        case .genre: .genre(id)
        case .song: nil
        }
    }
}

public enum Rating: String, Codable, Hashable, Sendable {
    case none = "INDIFFERENT"
    case like = "LIKE"
    case dislike = "DISLIKE"
}

/// One of the user's playlists, offered by "Save to playlist".
public struct PlaylistOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var thumbnail: String?
    /// The song is in it already.
    public var contains: Bool

    public init(id: String, title: String, thumbnail: String? = nil, contains: Bool = false) {
        self.id = id
        self.title = title
        self.thumbnail = thumbnail
        self.contains = contains
    }
}

public struct Lyrics: Codable, Hashable, Sendable {
    public var lines: [String]
    /// Each line's start in seconds when synced, else empty.
    public var starts: [Double]
    /// Where they come from, such as "Source: Musixmatch".
    public var source: String

    public init(lines: [String], starts: [Double] = [], source: String = "") {
        self.lines = lines
        self.starts = starts
        self.source = source
    }

    public var isSynced: Bool { !starts.isEmpty && starts.count == lines.count }

    /// The line playing at `time`, for synced lyrics.
    public func lineIndex(at time: Double) -> Int? {
        guard isSynced else { return nil }
        // Binary search: the last start at or before `time`.
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= time { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }
}

public struct Account: Codable, Hashable, Sendable {
    public var name: String
    public var handle: String?
    public var photo: String?

    public init(name: String, handle: String? = nil, photo: String? = nil) {
        self.name = name
        self.handle = handle
        self.photo = photo
    }
}

/// A failure fit to show: a sentence, never a URL or cookie.
public struct YTMError: Error, Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Hashable, Sendable {
        case network, http, parse, unplayable, notSignedIn, notFound, refused
    }

    public var kind: Kind
    public var message: String
    /// The HTTP status, when the failure was one.
    public var status: Int?

    public init(_ kind: Kind, _ message: String, status: Int? = nil) {
        self.kind = kind
        self.message = message
        self.status = status
    }

    public var description: String { message }
}

/// The sentence to show for a failure: YTMCore's own words, or the system's.
public func sentence(for error: any Error) -> String {
    (error as? YTMError)?.message ?? error.localizedDescription
}
