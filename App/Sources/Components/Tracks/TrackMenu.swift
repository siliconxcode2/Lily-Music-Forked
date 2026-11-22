import SwiftUI
import YTMCore

/// Laid out as iOS's own menus are: a symbol beside each item, and sections
/// for playing, the library and going elsewhere.
struct TrackMenu: View {
    let track: Track

    @Environment(AppModel.self) private var app

    var body: some View {
        Section {
            // The player says what it queued.
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { app.player.playNext([track]) }
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { app.player.addToQueue([track]) }
            Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { app.player.startRadio(from: track) }
        }
        Section {
            TrackDownloadItem(track: track)
            TrackLibraryMenu(track: track)
        }
        Section {
            TrackLinks(track: track)
        }
    }
}

struct TrackLinks: View {
    let track: Track

    @Environment(AppModel.self) private var app

    var body: some View {
        Button("Go to Artist", systemImage: "music.mic") { app.openArtist(of: track) }
            .disabled(track.firstArtistId == nil)
        Button("Go to Album", systemImage: "square.stack") { app.openAlbum(of: track) }
            .disabled(track.album == nil)
        ShareItem(link: track.link)
        Button("Copy Link", systemImage: "link") { app.copyLink(track.link) }
    }
}

/// iOS's share sheet, for Messages, AirDrop and the rest.
struct ShareItem: View {
    let link: String

    var body: some View {
        if let url = URL(string: link) {
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }
}

struct TrackLibraryMenu: View {
    let track: Track

    @Environment(AppModel.self) private var app
    @Environment(\.ownPlaylist) private var ownPlaylist

    var body: some View {
        if app.isSignedIn {
            let rating = app.rating(of: track)
            Button(rating == .like ? "Remove from Liked Songs" : "Like", systemImage: rating == .like ? "hand.thumbsup.fill" : "hand.thumbsup") {
                app.rate(track, .like)
            }
            Button(rating == .dislike ? "Remove Dislike" : "Dislike", systemImage: rating == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown") {
                app.rate(track, .dislike)
            }
            // Unknown for any but the playing song, so offered to clear.
            if !app.isPlaying(track) {
                Button("Remove Rating", systemImage: "hand.raised.slash") { app.rate(track, .none) }
            }
            Button("Save to Playlist", systemImage: "text.badge.plus") { app.addToPlaylist(track) }
            if let ownPlaylist {
                Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive) {
                    app.removeFromPlaylist(track, in: ownPlaylist)
                }
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
            Section {
                Button("Play", systemImage: "play") { app.play(card) }
                Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { app.startRadio(from: card) }
            }
        }
        Section {
            if pinsPlaylists, card.kind == .playlist, app.isSignedIn {
                let pinned = app.pinned.contains(card.id)
                Button(pinned ? "Unpin" : "Pin to Top", systemImage: pinned ? "pin.slash" : "pin") { app.togglePin(card) }
            }
            CardDownloadItem(card: card)
        }
        if let link = card.link {
            Section {
                ShareItem(link: link)
                Button("Copy Link", systemImage: "link") { app.copyLink(link) }
            }
        }
    }
}
