import Foundation

/// The parsers every page shares. Each returns nil for an item it can't read,
/// so an odd item is skipped and never fails the page.
enum Renderers {
    enum Item {
        case track(Track)
        case card(Card)
    }

    /// The parsed item in a `{"<kind>Renderer": {...}}` wrapper.
    static func item(_ wrapped: JSON, context: ItemContext = ItemContext()) -> Item? {
        guard let (key, renderer) = wrapped.onlyValue else { return nil }
        switch key {
        case "musicResponsiveListItemRenderer":
            if let track = track(renderer, context: context) { return .track(track) }
            return listCard(renderer, context: context).map(Item.card)
        case "musicTwoRowItemRenderer":
            return twoRowCard(renderer, context: context).map(Item.card)
        case "musicNavigationButtonRenderer":
            return genreCard(renderer).map(Item.card)
        default:
            return nil
        }
    }

    static func tracks(_ items: [JSON], context: ItemContext = ItemContext()) -> [Track] {
        items.compactMap { wrapped in
            guard case .track(let track)? = item(wrapped, context: context) else { return nil }
            return track
        }
    }

    static func cards(_ items: [JSON], context: ItemContext = ItemContext()) -> [Card] {
        items.compactMap { wrapped in
            guard case .card(let card)? = item(wrapped, context: context) else { return nil }
            return card
        }
    }
}

/// What the page around an item knows that the item itself leaves out.
struct ItemContext: Sendable {
    /// Album pages: the album every track is on.
    var album: AlbumRef?
    /// Album and artist pages: who the items are by when they don't say.
    var artists: [ArtistRef] = []
    /// The kind an unlabelled album tile is, as on an artist's singles shelf.
    var albumType: AlbumType = .album
    var subtitles: CardSubtitles = .composed
    /// Home: only official music videos count as videos, as uploads have no
    /// song version to look up.
    var musicVideosOnly = false
    /// The account's own playlist: each row keeps its entry ID, which edits take.
    var entries = false
}

enum CardSubtitles: Sendable {
    /// "Album • Artist • 2024", "Playlist • Channel", "1.2M subscribers".
    case composed
    /// As YouTube words it, as on Home.
    case asShown
}

enum AlbumType: Sendable {
    case album, ep, single, audiobook, show

    /// From YouTube's English label; nil for any other text.
    init?(label: String) {
        switch label.trimmingCharacters(in: .whitespaces).lowercased() {
        case "album", "albums": self = .album
        case "ep": self = .ep
        case "single", "singles": self = .single
        case "audiobook": self = .audiobook
        case "show": self = .show
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .album: "Album"
        case .ep: "EP"
        case .single: "Single"
        case .audiobook: "Audiobook"
        case .show: "Podcast"
        }
    }
}

// MARK: - Endpoints

extension Renderers {
    enum PageKind {
        case album, artist, playlist

        init?(pageType: String?) {
            switch pageType {
            case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK": self = .album
            case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_AUDIOBOOK_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL",
                 "WEB_PAGE_TYPE_CHANNEL": self = .artist
            case "MUSIC_PAGE_TYPE_PLAYLIST", "WEB_PAGE_TYPE_PLAYLIST": self = .playlist
            default: return nil
            }
        }
    }

    /// A `browseEndpoint`'s page kind and ID; playlists lose their browse IDs' `VL`.
    static func page(_ endpoint: JSON) -> (kind: PageKind, id: String)? {
        guard let id = endpoint["browseEndpoint", "browseId"].string, !id.isEmpty,
              let kind = PageKind(pageType: pageType(endpoint))
        else { return nil }
        return (kind, kind == .playlist ? playlistId(id) : id)
    }

    static func playlistId(_ browseId: String) -> String {
        browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId
    }

    /// The page a navigation endpoint opens, or nil for one that plays.
    static func route(_ endpoint: JSON) -> Route? {
        if let query = endpoint["searchEndpoint", "query"].string { return .search(query) }
        guard let id = endpoint["browseEndpoint", "browseId"].string, !id.isEmpty else { return nil }
        let params = endpoint["browseEndpoint", "params"].string.flatMap { $0.isEmpty ? nil : $0 }
        switch page(endpoint) {
        case (.album, let id)?: return .album(id)
        case (.artist, let id)?: return .artist(id)
        case (.playlist, let id)?: return .playlist(id)
        case nil: break
        }
        switch id {
        case "FEmusic_home": return .home
        case "FEmusic_explore": return .explore
        case "FEmusic_library_landing": return .library
        case "FEmusic_history": return .history
        case "FEmusic_new_releases": return .newReleases
        case "FEmusic_charts": return .charts
        case "FEmusic_moods_and_genres": return .moodsAndGenres
        case "FEmusic_moods_and_genres_category": return params.map(Route.genre)
        case "FEmusic_liked_playlists": return .libraryPlaylists
        case "FEmusic_liked_albums": return .libraryAlbums
        case "FEmusic_library_corpus_track_artists", "FEmusic_library_corpus_artists": return .libraryArtists
        case "FEmusic_liked_videos": return .librarySongs
        default: break
        }
        if id.hasPrefix("VL") { return .playlist(playlistId(id)) }
        if id.hasPrefix("MPRE") { return .album(id) }
        if id.hasPrefix("UC") { return .artist(id) }
        return .browse(id: id, params: params)
    }

    /// Whether the music video type is a video (OMV, UGC…) rather than a song
    /// (ATV) or podcast episode; nil when missing, except on Home, which counts only OMV.
    static func isVideo(_ watchEndpoint: JSON, context: ItemContext = ItemContext()) -> Bool? {
        let type = watchEndpoint["watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType"].string
        if context.musicVideosOnly { return type == "MUSIC_VIDEO_TYPE_OMV" }
        return type.map { $0 != "MUSIC_VIDEO_TYPE_ATV" && $0 != "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" }
    }

    static func token(_ continuationEndpoint: JSON) -> String? {
        let direct = continuationEndpoint["continuationCommand", "token"].string
        let nested = continuationEndpoint["commandExecutorCommand", "commands"].array.lazy
            .compactMap { $0["continuationCommand", "token"].string }.first
        return (direct ?? nested).flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - Runs

extension Renderers {
    /// Text runs split at YouTube's " • " separators: "Song • A & B • 3:45"
    /// gives three segments.
    static func segments(_ runs: [JSON]) -> [[JSON]] {
        var segments: [[JSON]] = [[]]
        for run in runs {
            if run["text"].string == " • " {
                segments.append([])
            } else {
                segments[segments.count - 1].append(run)
            }
        }
        return segments.filter { !$0.isEmpty }
    }

    static func text(_ runs: [JSON]) -> String {
        runs.lazy.compactMap { $0["text"].string }.joined()
    }

    static func linkedArtists(_ runs: [JSON]) -> [ArtistRef] {
        runs.compactMap { run in
            guard let name = run["text"].string, let id = run["navigationEndpoint", "browseEndpoint", "browseId"].string
            else { return nil }
            // Without a page type, a `UC` ID is a channel.
            let kind = PageKind(pageType: pageType(run["navigationEndpoint"]))
            return kind == .artist || (kind == nil && id.hasPrefix("UC")) ? ArtistRef(id: id, name: name) : nil
        }
    }

    /// Artists named without links, as uploads' are: the first non-label
    /// segment's even runs, as the odd ones are separators (", ", " & ").
    static func unlinkedArtists(_ segments: [[JSON]]) -> [ArtistRef] {
        guard let segment = segments.first(where: { !typeLabels.contains(text($0)) }) else { return [] }
        return segment.enumerated().compactMap { index, run in
            guard let name = run["text"].string, index.isMultiple(of: 2), name != "Various Artists" else { return nil }
            return ArtistRef(id: nil, name: name)
        }
    }

    /// The labels YouTube puts before an item's details.
    static let typeLabels: Set<String> = ["Song", "Video", "Episode", "Podcast", "Album", "Single", "EP", "Playlist", "Artist", "Profile"]

    static func album(_ runs: [JSON]) -> AlbumRef? {
        runs.lazy.compactMap { run -> AlbumRef? in
            guard let name = run["text"].string, case (.album, let id)? = page(run["navigationEndpoint"]) else { return nil }
            return AlbumRef(id: id, name: name)
        }.first
    }

    static func pageType(_ endpoint: JSON) -> String? {
        endpoint["browseEndpoint", "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType"].string
    }
}
