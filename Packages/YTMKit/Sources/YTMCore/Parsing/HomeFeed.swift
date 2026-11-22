import Foundation

/// The signed-in Home feed (`FEmusic_home`).
enum HomeFeed {
    /// Requests made for one page of the feed before giving up.
    static let attempts = 4
    /// Pages fetched at most after the first; the whole feed is five or six.
    static let continuations = 8
    static let listLimit = 10
    /// The web feed's Listen again, which YouTube's phone apps show as Speed dial.
    static let speedDialId = "FEmusic_listen_again"
    static let speedDialTitle = "Speed dial"
    /// For when the title leads nowhere; the feed is always in English (`InnerTube.language`).
    private static let speedDialTitles: Set<String> = ["Listen again", speedDialTitle]
    /// The shelves Home shows, in this order: those made from the account's own listening.
    static let shelfOrder = [
        speedDialTitle, "Quick picks", "Forgotten favorites", "Trending songs for you", "Mixed for you",
        "Fresh finds, old favorites",
    ]
    /// Of `shelfOrder`, the song lists; the rest are carousels, but Speed dial.
    static let songShelves: Set = ["Quick picks", "Trending songs for you"]
    /// The latest plays mixed into YouTube's Speed dial, which seldom has
    /// them, one after every `recentEvery` of its own picks, so they never lead it.
    static let recentPlays = 5
    static let recentEvery = 3
    /// Plays that make Speed dial when the feed has none: a first page beside the die.
    static let recentShelf = 8
    private static let shelfKinds: Set<String> = [
        "musicCarouselShelfRenderer", "musicImmersiveCarouselShelfRenderer", "musicShelfRenderer", "gridRenderer",
    ]

    /// YouTube refuses a share of signed-in feed requests in bursts with "400:
    /// invalid argument", then answers the same request a moment later.
    static func isRefusal(_ error: any Error) -> Bool {
        (error as? YTMError)?.status == 400
    }

    static func retryDelay(after attempt: Int) -> Duration {
        .milliseconds(300 * attempt)
    }

    static func firstPage(_ response: JSON) throws -> (sections: [Section], next: String?) {
        let list = response["contents", "singleColumnBrowseResultsRenderer", "tabs"][0]["tabRenderer", "content", "sectionListRenderer"]
        guard list.exists else { throw YTMError(.parse, "YouTube sent Home in a shape the app doesn't know.") }
        return (shelves(list), Renderers.continuation(list))
    }

    static func nextPage(_ response: JSON) -> (sections: [Section], next: String?) {
        let list = response["continuationContents", "sectionListContinuation"]
        return (shelves(list), Renderers.continuation(list))
    }

    /// Other shelves (the taste picker, banners) are skipped.
    private static func shelves(_ list: JSON) -> [Section] {
        let context = ItemContext(subtitles: .asShown, musicVideosOnly: true)
        return list["contents"].array.compactMap { wrapped -> Section? in
            guard let kind = wrapped.onlyValue?.key, shelfKinds.contains(kind) else { return nil }
            switch Renderers.section(wrapped, context: context) {
            case .tracks(var shelf)?:
                shelf.tracks = Array(shelf.tracks.prefix(listLimit))
                return .tracks(shelf)
            case let section?:
                return asSpeedDial(section)
            case nil:
                return nil
            }
        }
    }

    /// Listen again as Speed dial; any other section as it is.
    private static func asSpeedDial(_ section: Section) -> Section {
        guard case .cards(var shelf) = section, isSpeedDial(shelf), !shelf.cards.isEmpty else { return section }
        shelf.title = speedDialTitle
        shelf.layout = .speedDial
        return .cards(shelf)
    }

    private static func isSpeedDial(_ shelf: CardSection) -> Bool {
        if case .browse(let id, _)? = shelf.more, id == speedDialId { return true }
        return speedDialTitles.contains(shelf.title)
    }

    /// YouTube orders shelves differently each load, so each in `shelfOrder`
    /// is held until all above it arrive and Home never moves what's shown.
    /// Once `done`, only `shelfOrder`'s shelves are kept, or the whole feed if none came.
    static func release(_ held: inout [Section], after shown: [Section], done: Bool) -> [Section] {
        var out: [Section] = []
        if done, shown.isEmpty, !held.contains(where: { shelfOrder.contains($0.title) }) {
            out = held
            held = []
        }
        for title in shelfOrder {
            guard !(shown + out).contains(where: { $0.title == title }) else { continue }
            if let index = held.firstIndex(where: { $0.title == title }) {
                out.append(held.remove(at: index))
            } else if !done {
                break
            }
        }
        if done { held = [] }
        return out.map { section in
            guard case .tracks(var shelf) = section else { return section }
            shelf.mode = .radio
            return .tracks(shelf)
        }
    }

    /// Whether every shelf Home shows has arrived, after which nothing later in the feed can show.
    static func isComplete(_ sections: [Section]) -> Bool {
        shelfOrder.allSatisfy { title in sections.contains { $0.title == title } }
    }

    /// A whole feed, such as the saved one, as `release` shows it; one saved
    /// by an earlier version has Listen again under that name.
    static func arranged(_ sections: [Section]) -> [Section] {
        var held = sections.map(asSpeedDial)
        return release(&held, after: [], done: true)
    }

    /// Mixes up to `recentPlays` of `recent` into Speed dial, keeping its length,
    /// skipping ones it has, which stay where they are; with no Speed dial, makes one of `recentShelf`.
    static func addingRecent(_ sections: [Section], recent: [Track]) -> [Section] {
        var sections = sections
        guard let index = sections.firstIndex(where: { if case .cards(let s) = $0 { s.layout == .speedDial } else { false } }),
              case .cards(var shelf) = sections[index]
        else {
            let cards = recent.prefix(recentShelf).map(card)
            if !cards.isEmpty { sections.insert(.cards(CardSection(title: speedDialTitle, cards: cards, layout: .speedDial)), at: 0) }
            return sections
        }
        let count = shelf.cards.count
        let picked = Set(shelf.cards.map(\.id))
        let slots = stride(from: recentEvery, to: count, by: recentEvery + 1).prefix(recentPlays)
        let fresh = Array(zip(slots, recent.lazy.filter { !picked.contains($0.id) }))
        guard !fresh.isEmpty else { return sections }
        // In ascending order, each lands at its final index; YouTube's last picks drop off.
        for (slot, track) in fresh { shelf.cards.insert(card(track), at: slot) }
        shelf.cards.removeLast(fresh.count)
        sections[index] = .cards(shelf)
        return sections
    }

    /// YouTube can send Trending songs for you as a copy of Quick picks, so a
    /// track list drops songs an earlier one has, and goes if none are left.
    static func withoutRepeats(_ sections: [Section]) -> [Section] {
        var seen: Set<String> = []
        return sections.compactMap { section in
            guard case .tracks(var shelf) = section else { return section }
            shelf.tracks.removeAll { seen.contains($0.id) }
            seen.formUnion(shelf.tracks.map(\.id))
            return shelf.tracks.isEmpty ? nil : .tracks(shelf)
        }
    }

    private static func card(_ track: Track) -> Card {
        Card(
            kind: .song, id: track.id, title: track.title, subtitle: track.artistNames,
            thumbnail: track.thumbnail.map { Thumbnail.resized($0, edge: Thumbnail.card) }, track: track
        )
    }
}

extension Page {
    /// Applied as Home shows rather than as it loads, so a Home from the cache
    /// or the disk has what played since too, and repeats no list's songs.
    public func withRecentPlays(_ recent: [Track]) -> Page {
        Page(header: header, sections: HomeFeed.addingRecent(HomeFeed.withoutRepeats(sections), recent: recent), more: more)
    }
}
