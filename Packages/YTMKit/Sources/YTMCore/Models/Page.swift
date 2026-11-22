import Foundation

/// How tapping one track of a section fills the queue.
public enum QueueMode: String, Codable, Hashable, Sendable {
    /// Queue the whole section from the tapped track.
    case section
    /// Play the track, then a radio based on it.
    case radio
}

public enum CardLayout: String, Codable, Hashable, Sendable {
    case carousel, grid, chips
    /// One large card for the best search match.
    case top
    /// YouTube Music's Speed dial: pages of three by three tiles.
    case speedDial
}

public struct TrackSection: Codable, Hashable, Sendable {
    public var title: String
    public var tracks: [Track]
    public var mode: QueueMode
    /// Album pages show track numbers instead of artwork.
    public var numbered: Bool
    public var more: Route?

    public init(title: String, tracks: [Track], mode: QueueMode, numbered: Bool = false, more: Route? = nil) {
        self.title = title
        self.tracks = tracks
        self.mode = mode
        self.numbered = numbered
        self.more = more
    }
}

public struct CardSection: Codable, Hashable, Sendable {
    public var title: String
    public var cards: [Card]
    public var layout: CardLayout
    public var more: Route?

    public init(title: String, cards: [Card], layout: CardLayout, more: Route? = nil) {
        self.title = title
        self.cards = cards
        self.layout = layout
        self.more = more
    }
}

public enum Section: Codable, Hashable, Sendable {
    case tracks(TrackSection)
    case cards(CardSection)

    public var title: String {
        switch self {
        case .tracks(let s): s.title
        case .cards(let s): s.title
        }
    }

    public var more: Route? {
        switch self {
        case .tracks(let s): s.more
        case .cards(let s): s.more
        }
    }

    /// Empty sections are not worth a row.
    public static func tracks(_ title: String, _ tracks: [Track], mode: QueueMode, numbered: Bool = false, more: Route? = nil) -> Section? {
        tracks.isEmpty ? nil : .tracks(TrackSection(title: title, tracks: tracks, mode: mode, numbered: numbered, more: more))
    }

    public static func cards(_ title: String, _ cards: [Card], layout: CardLayout, more: Route? = nil) -> Section? {
        cards.isEmpty ? nil : .cards(CardSection(title: title, cards: cards, layout: layout, more: more))
    }
}

public struct PageHeader: Codable, Hashable, Sendable {
    /// "Album", "Single", "Playlist", "Artist"…, shown above the title.
    public var label: String
    public var title: String
    public var subtitle: String
    /// Counts and lengths: "12 songs • 43 min".
    public var meta: String
    public var description: String?
    public var thumbnail: String?
    /// Artists show a wide image behind the title.
    public var banner: Bool
    /// Playlist whose tracks Shuffle loads when the page's are incomplete.
    public var shufflePlaylistId: String?
    public var radioId: String?
    /// The playlist holding the page's songs, whose rest Play and Shuffle load when the page's are unfinished.
    public var playlistId: String?
    // Optional, as are those below, so a page saved before they were read still decodes.
    /// A playlist's song count, counting those not loaded.
    public var count: Int?
    /// True for one of the account's own playlists, which it can edit.
    public var editable: Bool?
    /// Who can see the account's own playlist.
    public var privacy: PlaylistPrivacy?
    /// Whether the album or playlist is in the library, saved by `playlistId`; unknown signed out and on the
    /// account's own playlists.
    public var saved: Bool?
    /// Whether the account is subscribed to the artist; unknown signed out.
    public var subscribed: Bool?
    /// The channel subscribing to the artist takes.
    public var channelId: String?

    public init(
        label: String = "", title: String, subtitle: String = "", meta: String = "",
        description: String? = nil, thumbnail: String? = nil,
        banner: Bool = false, shufflePlaylistId: String? = nil, radioId: String? = nil,
        playlistId: String? = nil
    ) {
        self.label = label
        self.title = title
        self.subtitle = subtitle
        self.meta = meta
        self.description = description
        self.thumbnail = thumbnail
        self.banner = banner
        self.shufflePlaylistId = shufflePlaylistId
        self.radioId = radioId
        self.playlistId = playlistId
    }
}

/// What a page still has to fetch after it shows; `YTMusic.loadMore`
/// fetches one step of it at a time.
public enum Continuation: Codable, Hashable, Sendable {
    /// The rest of a long playlist's tracks. `seen` holds the entry IDs listed so far, so a batch that repeats
    /// them drops them. `fetched` counts the tracks so far, repeats included, against `YTMusic.playlistLimit`.
    case tracks(token: String, seen: Set<String> = [], fetched: Int = 0)
    /// The Home feed's further shelves, with those read but held back
    /// until the ones above them in `HomeFeed.shelfOrder` arrive.
    case shelves(token: String, pagesLeft: Int, held: [Section])
}

public struct Page: Codable, Hashable, Sendable {
    public var header: PageHeader?
    public var sections: [Section]
    public var more: Continuation?

    public init(header: PageHeader? = nil, sections: [Section], more: Continuation? = nil) {
        self.header = header
        self.sections = sections
        self.more = more
    }

    /// What the header's Play and Shuffle buttons queue: the page's track
    /// list, which comes first.
    public var headerTracks: [Track] {
        guard header != nil, case .tracks(let s)? = sections.first else { return [] }
        return s.tracks
    }
}

public enum Route: Codable, Hashable, Sendable {
    case home, explore, library, history
    case search(String)
    case album(String)
    case playlist(String)
    case artist(String)
    /// A mood or genre, by its browse params.
    case genre(String)
    case libraryPlaylists, libraryAlbums, libraryArtists, librarySongs
    /// "More" on an artist's discography or a Home shelf.
    case browse(id: String, params: String?)
    case newReleases, charts, moodsAndGenres
    /// The songs, albums and playlists kept on the phone, which the app lists itself.
    case downloads

    public static let likedSongs = Route.playlist(BuiltInPlaylist.likedMusic)
}

enum BuiltInPlaylist {
    /// Liked music, an auto playlist.
    static let likedMusic = "LM"
    /// Episodes for later, a podcast page, which doesn't open as a playlist.
    static let episodesForLater = "SE"
    /// The "Shuffle all" row.
    static let shuffleAll = "MLCT"
    static let skippedInLists: Set = [likedMusic, shuffleAll, episodesForLater]
}
