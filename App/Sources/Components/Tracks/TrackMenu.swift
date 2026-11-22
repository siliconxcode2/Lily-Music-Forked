import SwiftUI
import YTMCore

struct TrackMenu: View {
    let track: Track

    @Environment(AppModel.self) private var app

    var body: some View {
        // The player says what it queued.
        Button("Play next") { app.player.playNext([track]) }
        Button("Add to queue") { app.player.addToQueue([track]) }
        Button("Start radio") { app.player.startRadio(from: track) }
        TrackDownloadItem(track: track)

        TrackLibraryMenu(track: track)

        Divider()
        TrackLinks(track: track)
    }
}

struct TrackLinks: View {
    let track: Track

    @Environment(AppModel.self) private var app

    var body: some View {
        Button("Go to artist") { app.openArtist(of: track) }
            .disabled(track.firstArtistId == nil)
        Button("Go to album") { app.openAlbum(of: track) }
            .disabled(track.album == nil)
        Button("Copy link") { app.copyLink(track.link) }
    }
}

struct TrackLibraryMenu: View {
    let track: Track

    @Environment(AppModel.self) private var app
    @Environment(\.ownPlaylist) private var ownPlaylist

    var body: some View {
        if app.isSignedIn {
            Divider()
            let rating = app.rating(of: track)
            Button(rating == .like ? "Remove from liked songs" : "Like") { app.rate(track, .like) }
            Button(rating == .dislike ? "Remove dislike" : "Dislike") { app.rate(track, .dislike) }
            // Unknown for any but the playing song, so offered to clear.
            if !app.isPlaying(track) {
                Button("Remove rating") { app.rate(track, .none) }
            }
            Button("Save to playlist") { app.addToPlaylist(track) }
            if let ownPlaylist {
                Button("Remove from playlist") { app.removeFromPlaylist(track, in: ownPlaylist) }
            }
        }
    }
}

struct CardMenu: View {
    let card: Card

    @Environment(AppModel.self) private var app
    @Environment(\.pinsPlaylists) private var pinsPlaylists

    var body: some View {
        if card.kind != .genre {
            Button("Play") { app.play(card) }
            Button("Start radio") { app.startRadio(from: card) }
        }
        if pinsPlaylists, card.kind == .playlist, app.isSignedIn {
            Button(app.pinned.contains(card.id) ? "Unpin" : "Pin to top") { app.togglePin(card) }
        }
        CardDownloadItem(card: card)
        if let link = card.link {
            Button("Copy link") { app.copyLink(link) }
        }
    }
}
