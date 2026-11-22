import Foundation

// Edits to the account's own playlists and library, shown on its pages at once. Pure, so the app's optimistic edits
// and their undoing are tested here.

/// Who can see a playlist.
public enum PlaylistPrivacy: String, Codable, CaseIterable, Hashable, Sendable {
    case `public` = "PUBLIC"
    case unlisted = "UNLISTED"
    case `private` = "PRIVATE"
}

/// Where a song moved in the account's own playlist lands.
public enum Successor: Equatable, Sendable {
    /// Before this entry.
    case before(String)
    /// Last.
    case end

    /// The entry `YTMusic.moveInPlaylist` takes; nil for last.
    public var entry: String? {
        if case .before(let entry) = self { entry } else { nil }
    }
}

extension Page {
    /// Takes the entry out of the page's songs: where it was, the song, and the entry that followed it.
    public mutating func takeEntry(_ entry: String) -> (at: Int, track: Track, next: String?)? {
        let taken = editSongs { tracks -> (at: Int, track: Track, next: String?)? in
            guard let at = tracks.firstIndex(where: { $0.setVideoId == entry }) else { return nil }
            let track = tracks.remove(at: at)
            return (at, track, tracks.indices.contains(at) ? tracks[at].setVideoId : nil)
        }
        if taken != nil { recount(-1) }
        return taken
    }

    /// Puts `track` among the page's songs before the entry `before`, last without one, or at `at` should that
    /// entry be gone too; answers where. Nil should the songs hold it already, as a fresh copy would.
    public mutating func putEntry(_ track: Track, before: String?, at: Int) -> Int? {
        let put = editSongs { tracks -> Int? in
            guard !tracks.contains(where: { $0.setVideoId == track.setVideoId }) else { return nil }
            let index = before.map { before in
                tracks.firstIndex { $0.setVideoId == before } ?? min(at, tracks.count)
            } ?? tracks.count
            tracks.insert(track, at: index)
            return index
        }
        if put != nil { recount(1) }
        return put
    }

    /// Moves the entry before `before`, as `putEntry` places it: from where to where, and the entry that followed it.
    public mutating func shiftEntry(_ entry: String, before: String?, at: Int) -> (from: Int, to: Int, next: String?)? {
        guard let (from, track, next) = takeEntry(entry), let to = putEntry(track, before: before, at: at) else { return nil }
        return (from, to, next)
    }

    /// The entry the song at `from` lands before once at `to`. Nil where that can't be said: beside a song without
    /// an entry ID, or past the songs loaded while the playlist has more than that.
    public func successor(from: Int, to: Int) -> Successor? {
        let tracks = headerTracks
        var rest = tracks
        if rest.indices.contains(from) { rest.remove(at: from) }
        guard rest.indices.contains(to) else {
            return (header?.count ?? 0) <= tracks.count ? .end : nil
        }
        return rest[to].setVideoId.map(Successor.before)
    }

    /// The page with `live`'s saved and subscribed flags, as a copy fetched before they changed may not have them.
    public func keepingLibraryState(of live: Page?) -> Page {
        guard let live = live?.header, header != nil else { return self }
        var page = self
        page.header?.saved = live.saved
        page.header?.subscribed = live.subscribed
        return page
    }

    /// Shows the album or playlist saved by `id`, or the artist subscribed to by it, as `on`; false for a page that
    /// changes by another ID, or none.
    public mutating func setInLibrary(subscribe: Bool, id: String, on: Bool) -> Bool {
        guard let header else { return false }
        if subscribe {
            guard header.subscribed != nil, header.channelId == id else { return false }
            self.header?.subscribed = on
        } else {
            guard header.saved != nil, header.playlistId == id else { return false }
            self.header?.saved = on
        }
        return true
    }

    private mutating func editSongs<R>(_ edit: (inout [Track]) -> R?) -> R? {
        guard header != nil, case .tracks(var section)? = sections.first, let result = edit(&section.tracks) else { return nil }
        sections[0] = .tracks(section)
        return result
    }

    /// Counts `change` more songs in the header, whose count takes in those past the ones loaded.
    private mutating func recount(_ change: Int) {
        let count = header?.count.map { max($0 + change, 0) }
        let meta = Formatting.playlistMeta(count: count, tracks: headerTracks)
        header?.count = count
        header?.meta = meta
    }
}

extension Route {
    /// `stack` without `gone`, nor the repeats that leaves side by side, so going back never lands on it.
    public static func forgetting(_ gone: Route, in stack: [Route]) -> [Route] {
        stack.filter { $0 != gone }.reduce(into: []) { kept, route in
            if kept.last != route { kept.append(route) }
        }
    }
}
