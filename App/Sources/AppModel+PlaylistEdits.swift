import Foundation
import YTMCore

/// Edits to the account's own playlists, from the page showing one. Songs removed or moved show so at once, and
/// go back should YouTube refuse.
extension AppModel {
    /// The ID of the account's own playlist `model` shows, loaded whole so every entry's place is known, which its
    /// menus and dragging offer to edit.
    func ownPlaylist(_ model: PageModel?) -> String? {
        guard isSignedIn, let model, case .playlist(let id) = model.route, let page = model.page, page.more == nil,
              page.header?.editable == true
        else { return nil }
        return id
    }

    /// Applies `change` to the route's cached copy and to `model`'s page, answering what it gave there, else in the
    /// cache. A change is counted, so a load asked for before it never puts it back. The copy then counts as fresh,
    /// as YouTube may not show the edit yet; without `renewing`, one already expired stays so.
    @discardableResult
    func editPage<R>(_ route: Route, shown model: PageModel?, renewing: Bool = true, _ change: (inout Page) -> R?) -> R? {
        pageEdits[route, default: 0] += 1
        var cached: R?
        if var kept = pageCache[route], let result = change(&kept.page) {
            cached = result
            // A new time either way, so a screen showing the old copy takes this one on a return.
            kept.at = renewing || kept.isFresh ? .now : .now - Self.pageFreshFor
            pageCache[route] = kept
            if route == .library { api.saveLibrary(kept.page) }
        }
        let shown = model.flatMap { $0.route == route ? $0.edit(in: self, cachedAt: pageCache[route]?.at, change) : nil }
        return shown ?? cached
    }

    func removeFromPlaylist(_ track: Track, in model: PageModel) {
        guard let id = ownPlaylist(model) else { return }
        guard let entry = track.setVideoId else { return showToast("Can't remove the song") }
        let route = model.route
        guard let taken = editPage(route, shown: model, { $0.takeEntry(entry) }) else { return }
        let generation = accountGeneration
        Task { [api] in
            do {
                try await api.removeFromPlaylist(id, tracks: [track])
                // The Library pages show each playlist's song count.
                if generation == accountGeneration { [Route.library, .libraryPlaylists].forEach(forget) }
            } catch {
                if generation == accountGeneration {
                    editPage(route, shown: model) { $0.putEntry(track, before: taken.next, at: taken.at) }
                }
                showToast("Couldn't remove \u{201C}\(track.title)\u{201D}: \(sentence(for: error))")
            }
        }
    }

    /// Moves the entry, as dragged, to where the song at `target` is.
    func moveInPlaylist(_ entry: String, to target: Int, in model: PageModel) {
        guard let id = ownPlaylist(model), let page = model.page else { return }
        let tracks = page.headerTracks
        guard let from = tracks.firstIndex(where: { $0.setVideoId == entry }) else { return }
        let to = min(max(target, 0), tracks.count - 1)
        guard from != to else { return }
        guard let successor = page.successor(from: from, to: to) else { return showToast("Can't move the song there") }
        let route = model.route
        guard let moved = editPage(route, shown: model, { $0.shiftEntry(entry, before: successor.entry, at: to) }) else { return }
        let generation = accountGeneration
        Task { [api] in
            do {
                try await api.moveInPlaylist(id, entry: entry, before: successor.entry)
            } catch {
                // Back before the entry it followed.
                if generation == accountGeneration {
                    editPage(route, shown: model) { $0.shiftEntry(entry, before: moved.next, at: moved.from) }
                }
                showToast("Couldn't move the song: \(sentence(for: error))")
            }
        }
    }

    /// Not shown until YouTube has it; a name unchanged or empty does nothing.
    func renamePlaylist(in model: PageModel, to name: String) {
        guard let id = ownPlaylist(model), let old = model.page?.header?.title else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return }
        let generation = accountGeneration
        Task { [api] in
            do {
                try await api.renamePlaylist(id, title: name)
            } catch {
                return showToast("Couldn't rename the playlist: \(sentence(for: error))")
            }
            guard generation == accountGeneration else { return }
            editPage(model.route, shown: model) { page -> Void? in page.header?.title = name }
            editLibraryPlaylist(id) { cards, at in cards[at].title = name }
        }
    }

    /// Not shown until YouTube has it.
    func setPrivacy(_ privacy: PlaylistPrivacy, in model: PageModel) {
        guard let id = ownPlaylist(model), model.page?.header?.privacy != privacy else { return }
        let generation = accountGeneration
        Task { [api] in
            do {
                try await api.setPrivacy(privacy, ofPlaylist: id)
            } catch {
                return showToast("Couldn't change who can see the playlist: \(sentence(for: error))")
            }
            if generation == accountGeneration {
                editPage(model.route, shown: model) { page -> Void? in page.header?.privacy = privacy }
            }
            let shown = switch privacy {
            case .public: "Anyone can find the playlist now"
            case .unlisted: "Anyone with the link can see the playlist now"
            case .private: "Only you can see the playlist now"
            }
            showToast(shown)
        }
    }

    /// Takes it out of every tab's pages, so it is left should it be on screen and Back never lands on it, and off
    /// the pins. A download of it stays, as removing that is the user's to choose.
    func deletePlaylist(in model: PageModel) {
        guard let id = ownPlaylist(model), let title = model.page?.header?.title else { return }
        let generation = accountGeneration
        Task { [api] in
            do {
                try await api.deletePlaylist(id)
            } catch {
                return showToast("Couldn't delete \u{201C}\(title)\u{201D}: \(sentence(for: error))")
            }
            showToast("Deleted \u{201C}\(title)\u{201D}")
            guard generation == accountGeneration else { return }
            let route = model.route
            forget(route)
            for tab in AppTab.allCases {
                let stack = navigation(for: tab)
                let kept = Route.forgetting(route, in: stack.routes)
                if kept != stack.routes { stack.routes = kept }
            }
            if settings.value.pinned.contains(id) { settings.value.pinned.removeAll { $0 == id } }
            editLibraryPlaylist(id) { cards, at in cards.remove(at: at) }
        }
    }

    /// Signed in or out meanwhile, the playlist is the last account's, so Library is left be.
    func saveQueueAsPlaylist() {
        let generation = accountGeneration
        Task {
            guard let card = await player.saveQueueAsPlaylist(), generation == accountGeneration else { return }
            editLibraryPlaylists { cards in
                guard !cards.contains(where: { $0.id == card.id }) else { return false }
                // First among the account's own, after Liked music.
                cards.insert(card, at: cards.firstIndex { $0.id.hasPrefix("PL") } ?? cards.endIndex)
                return true
            }
            playlistsAdded += 1
        }
    }

    private func editLibraryPlaylist(_ id: String, _ edit: (inout [Card], Int) -> Void) {
        editLibraryPlaylists { cards in
            guard let at = cards.firstIndex(where: { $0.kind == .playlist && $0.id == id }) else { return false }
            edit(&cards, at)
            return true
        }
    }

    /// Shows a change to the account's playlists on Library's pages, and the copy saved for the next start, at once,
    /// as YouTube's lists can take a moment to. `edit` answers whether it changed the cards of a section of playlists.
    private func editLibraryPlaylists(_ edit: (inout [Card]) -> Bool) {
        for route in [Route.library, .libraryPlaylists] {
            // An expired copy stays expired, rather than passing an old Library off as current.
            editPage(route, shown: nil, renewing: false) { page -> Void? in
                var found = false
                for index in page.sections.indices {
                    guard case .cards(var section) = page.sections[index], section.cards.contains(where: { $0.kind == .playlist }),
                          edit(&section.cards)
                    else { continue }
                    page.sections[index] = .cards(section)
                    found = true
                }
                return found ? () : nil
            }
        }
    }
}
