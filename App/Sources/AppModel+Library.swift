import Foundation
import YTMCore

extension AppModel {
    /// Saves the page's album or playlist to the library, or subscribes to its artist, or undoes that: shown at
    /// once, and put back should YouTube refuse.
    func toggleInLibrary(subscribe: Bool, in model: PageModel) {
        guard let header = model.page?.header else { return }
        let (now, id) = subscribe ? (header.subscribed, header.channelId) : (header.saved, header.playlistId)
        guard let now, let id, !libraryEdits.contains(id) else { return }
        let on = !now
        let (done, what) = switch (subscribe, on) {
        case (false, true): ("Saved to your library", "save it to your library")
        case (false, false): ("Removed from your library", "remove it from your library")
        case (true, true): ("Subscribed to \(header.title)", "subscribe")
        case (true, false): ("Unsubscribed from \(header.title)", "unsubscribe")
        }
        libraryEdits.insert(id)
        let route = model.route
        let generation = accountGeneration
        showInLibrary(route, model, subscribe: subscribe, id: id, on: on)
        Task { [api] in
            let failure: (any Error)?
            do {
                if subscribe { try await api.setSubscribed(on, channelId: id) } else { try await api.setSaved(on, playlistId: id) }
                failure = nil
            } catch {
                failure = error
            }
            libraryEdits.remove(id)
            // Signed in or out meanwhile: the pages shown are another account's.
            guard generation == accountGeneration else { return }
            // Again on success too, as a load answered before YouTube had the change shows it undone.
            showInLibrary(route, model, subscribe: subscribe, id: id, on: failure == nil ? on : !on)
            if let failure {
                showToast("Couldn't \(what): \(sentence(for: failure))")
                return
            }
            // The Library pages list what was saved, so they load afresh.
            forget(.library)
            if let list = Self.libraryList(of: route) { forget(list) }
            showToast(done)
        }
    }

    /// The cached copy keeps when it was fetched, so it reloads when it would have.
    private func showInLibrary(_ route: Route, _ model: PageModel, subscribe: Bool, id: String, on: Bool) {
        libraryRevisions[route, default: 0] += 1
        _ = pageCache[route]?.page.setInLibrary(subscribe: subscribe, id: id, on: on)
        _ = model.edit(in: self) { $0.setInLibrary(subscribe: subscribe, id: id, on: on) ? () : nil }
    }

    private static func libraryList(of route: Route) -> Route? {
        switch route {
        case .album: .libraryAlbums
        case .playlist: .libraryPlaylists
        case .artist: .libraryArtists
        default: nil
        }
    }
}
