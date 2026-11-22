import Foundation

extension YTMusic {
    /// The full discography is asked alongside the page, and stands in for the page's own
    /// releases when it has more.
    func artistPage(_ id: String) async throws -> Page {
        async let page = artist(id)
        async let discography = try? releases(of: id)
        var artist = try await page
        // An alias redirects to the artist's own ID, which the discography
        // must be asked by.
        let all = artist.id == id ? await discography : try? await releases(of: artist.id)
        try Task.checkCancellation()
        if let all, all.count > artist.releases.count {
            artist.releases = all
        }
        return artist.page
    }

    /// Asked again by the artist's own ID when `id` is an alias; as the account sees it, for whether it is subscribed.
    func artist(_ id: String) async throws -> ArtistDetails {
        func fetch(_ id: String) async throws -> ArtistDetails {
            let (response, signedIn) = try await asAccount(true) { try await self.innerTube.browse(id, authenticated: $0) }
            return try Renderers.artist(response, id: id, signedIn: signedIn)
        }
        let artist = try await fetch(id)
        return artist.id == id ? artist : try await fetch(artist.id)
    }

    private func releases(of artistId: String) async throws -> [ArtistRelease] {
        let response = try await innerTube.browse("MPAD" + artistId, params: Self.newestFirst, authenticated: false)
        let name = response["header", "musicHeaderRenderer", "title"].text ?? ""
        let context = ItemContext(artists: [ArtistRef(id: artistId, name: name)])
        var releases: [ArtistRelease] = []
        for grid in Renderers.sectionList(in: response)["contents"].array.map({ $0["gridRenderer"] }) where grid.exists {
            releases += grid["items"].array.compactMap { Renderers.release($0, context: context) }
            try await following(grid, authenticated: false) { batch in
                releases += batch.compactMap { Renderers.release($0, context: context) }
            }
        }
        return releases
    }

    /// The discography's params: every kind of release, newest first, as
    /// rustypipe's `albums_param(None, Some(AlbumOrder::Recency))`.
    private static let newestFirst = "ggMIegYQARoCAQI%3D"
}

struct ArtistRelease {
    var card: Card
    var type: AlbumType
}

struct ArtistDetails {
    /// Differs from the one asked for when that was an alias.
    var id: String
    var header: PageHeader
    var songs: [Track] = []
    var songsMore: Route?
    var releases: [ArtistRelease] = []
    var albumsMore: Route?
    var singlesMore: Route?
    var playlists: [Card] = []
    var related: [Card] = []

    var page: Page {
        let singles = releases.filter { $0.type == .single || $0.type == .ep }.map(\.card)
        let albums = releases.filter { $0.type != .single && $0.type != .ep }.map(\.card)
        let sections = [
            Section.tracks("Songs", songs, mode: .section, more: songsMore),
            .cards("Albums", albums, layout: .carousel, more: albumsMore),
            .cards("Singles & EPs", singles, layout: .carousel, more: singlesMore),
            .cards("Featured on", playlists, layout: .carousel),
            .cards("Fans might also like", related, layout: .carousel),
        ]
        return Page(header: header, sections: sections.compactMap(\.self))
    }
}

extension Renderers {
    /// `signedIn` when the account's own request was answered as its, as only then does the subscribe button say
    /// whether it is subscribed.
    static func artist(_ response: JSON, id: String, signedIn: Bool) throws -> ArtistDetails {
        let header = response["header"].first("musicImmersiveHeaderRenderer", "musicVisualHeaderRenderer")
        guard let name = header["title"].text, !name.isEmpty else {
            throw YTMError(.notFound, "This artist isn't available.")
        }
        let ownId = header["shareEndpoint", "shareEntityEndpoint", "serializedShareEntity"].string
            .flatMap(sharedChannelId) ?? id
        let subscription = header["subscriptionButton", "subscribeButtonRenderer"]
        let subscribers = subscription["subscriberCountText"].text.flatMap(Formatting.count)
        // Wide banners must keep their aspect, so the largest is taken as is.
        let banner = Thumbnail.list(in: header).array
            .max { ($0["width"].int ?? 0) < ($1["width"].int ?? 0) }?["url"].string
        var artist = ArtistDetails(id: ownId, header: PageHeader(
            label: "Artist",
            title: name,
            subtitle: subscribers.map { "\(Formatting.compact($0)) subscribers" } ?? "",
            description: header["description"].text,
            thumbnail: banner,
            banner: true,
            radioId: header["startRadioButton", "buttonRenderer", "navigationEndpoint", "watchEndpoint", "playlistId"].string
        ))
        // Signed out, YouTube says false whatever the account does.
        if subscription.exists, signedIn { artist.header.subscribed = subscription["subscribed"].bool ?? false }
        artist.header.channelId = subscription["channelId"].string

        var context = ItemContext(artists: [ArtistRef(id: ownId, name: name)])
        for wrapped in sectionList(in: response)["contents"].array {
            let list = wrapped["musicShelfRenderer"]
            if list.exists {
                artist.songs += tracks(list["contents"].array, context: context)
                if artist.songsMore == nil, case .playlist(let playlist)? = route(list["bottomEndpoint"]) {
                    artist.songsMore = .playlist(playlist)
                    artist.header.shufflePlaylistId = playlist
                }
                continue
            }
            let carousel = wrapped["musicCarouselShelfRenderer"]
            let shelfHeader = carousel["header", "musicCarouselShelfBasicHeaderRenderer"]
            // The untitled shelf holds the artist's own channel, not a page the app opens.
            guard let title = shelfHeader["title"].text, !title.isEmpty else { continue }
            let more = route(shelfHeader["moreContentButton", "buttonRenderer", "navigationEndpoint"])
            context.albumType = AlbumType(label: title) ?? (title.contains("Single") ? .single : .album)
            for item in carousel["contents"].array {
                switch Renderers.item(item, context: context) {
                case .track(let track)?:
                    artist.songs.append(track)
                case .card(let card)?:
                    switch card.kind {
                    case .album:
                        let type = releaseType(item["musicTwoRowItemRenderer"]) ?? context.albumType
                        artist.releases.append(ArtistRelease(card: card, type: type))
                        if context.albumType == .single || context.albumType == .ep {
                            artist.singlesMore = artist.singlesMore ?? more
                        } else {
                            artist.albumsMore = artist.albumsMore ?? more
                        }
                    case .song:
                        // Music videos follow the top songs in one list.
                        if let track = card.track { artist.songs.append(track) }
                    case .playlist: artist.playlists.append(card)
                    case .artist: artist.related.append(card)
                    case .genre: break
                    }
                case nil:
                    break
                }
            }
        }
        return artist
    }

    static func release(_ wrapped: JSON, context: ItemContext) -> ArtistRelease? {
        guard case .card(let card)? = item(wrapped, context: context), card.kind == .album else { return nil }
        return ArtistRelease(card: card, type: releaseType(wrapped["musicTwoRowItemRenderer"]) ?? context.albumType)
    }

    private static func releaseType(_ tile: JSON) -> AlbumType? {
        segments(tile["subtitle"].runs).lazy.compactMap { AlbumType(label: text($0)) }.first
    }

    /// Field 3 of the base64 protobuf: the artist's own ID when the page was asked for by an alias.
    static func sharedChannelId(_ serialized: String) -> String? {
        guard var base64 = serialized.removingPercentEncoding else { return nil }
        base64 = base64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        var bytes = data[...]
        while let key = varint(&bytes) {
            let length: UInt64
            switch key & 7 {
            case 0:
                guard varint(&bytes) != nil else { return nil }
                continue
            case 1: length = 8
            case 2:
                guard let n = varint(&bytes) else { return nil }
                length = n
            case 5: length = 4
            default: return nil
            }
            guard length <= UInt64(bytes.count) else { return nil }
            let value = bytes.prefix(Int(length))
            if key >> 3 == 3, key & 7 == 2 { return String(bytes: value, encoding: .utf8) }
            bytes = bytes.dropFirst(Int(length))
        }
        return nil
    }

    private static func varint(_ bytes: inout Data.SubSequence) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while let byte = bytes.popFirst(), shift < 64 {
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
}
