import Foundation
import UIKit
import YTMCore

enum HeaderAction {
    case play, shuffle, radio
}

extension AppModel {
    /// A card opens its page; a song card plays, with a radio after it.
    func activate(_ card: Card, displayScale: CGFloat) {
        guard let route = card.route else { return play(card) }
        switch route {
        case .album, .playlist:
            // The header's cover is the card's, so its fetch overlaps the page's rather than following it.
            // An artist's header is a wide banner, never the card's square, so it isn't fetched ahead.
            if let url = card.thumbnail {
                let pixels = ArtworkImage.pixels(edge: Metrics.headerArt, scale: displayScale)
                Task { _ = await ImagePipeline.shared.image(for: url, pixelEdge: pixels) }
            }
        default:
            break
        }
        open(route)
    }

    /// An album or playlist plays from the page cached, and a long playlist's whole copy replaces its first page
    /// once queued, so opening it next shows it all at once.
    func play(_ card: Card) {
        let generation = accountGeneration
        Task {
            await player.play(card, page: cardPage(card), whole: { [self] whole in
                // Only over a copy still half-loaded, as one completed meanwhile may be newer, and for this account.
                guard generation == accountGeneration, let route = card.route, let kept = pageCache[route], kept.page.more != nil
                else { return }
                pageCache[route]?.page = whole.keepingLibraryState(of: kept.page)
            })
        }
    }

    /// A playlist's own radio, else one from its first song.
    func startRadio(from card: Card) {
        Task { await player.startRadio(from: card, page: cardPage(card)) }
    }

    /// An album's or playlist's page fresh in the cache, else fetched into it.
    private func cardPage(_ card: Card) -> (@MainActor @Sendable () async throws -> Page)? {
        guard card.kind == .album || card.kind == .playlist, let route = card.route else { return nil }
        return { [self] in
            // An expired copy may be missing songs added since.
            if let kept = pageCache[route], kept.isFresh { return kept.page }
            return try await fetchPage(route)
        }
    }

    func perform(_ action: HeaderAction, on page: Page) {
        Task {
            switch action {
            case .play: await player.play(page)
            case .shuffle: await player.play(page, shuffle: true)
            case .radio:
                if let radio = page.header?.radioId { await player.startRadio(playlistId: radio) }
            }
        }
    }

    func isPlaying(_ track: Track) -> Bool {
        player.current?.id == track.id
    }

    /// How the account rated `track`: only the playing song's is known.
    func rating(of track: Track) -> Rating {
        isPlaying(track) ? player.rating : .none
    }

    /// Toggles the rating; `.none` removes either. The player says how it went and skips a
    /// disliked song that is playing.
    func rate(_ track: Track, _ requested: Rating) {
        player.rate(requested, track: track)
    }

    func addToPlaylist(_ track: Track) {
        // From Now Playing the picker stacks on it.
        if sheet == .nowPlaying { nowPlayingPicker = track } else { sheet = .addToPlaylist(track) }
    }

    func openArtist(of track: Track) {
        if let id = track.firstArtistId { open(.artist(id)) }
    }

    func openAlbum(of track: Track) {
        if let album = track.album { open(.album(album.id)) }
    }

    /// The pasteboard never prompts or fails, so the toast always confirms.
    func copyLink(_ link: String) {
        UIPasteboard.general.string = link
        showToast("Link copied")
    }
}
