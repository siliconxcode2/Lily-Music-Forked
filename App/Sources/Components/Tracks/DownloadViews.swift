import SwiftUI
import YTMCore
import YTMPlayback

/// Its own view, so download progress redraws the badge rather than the whole row.
struct DownloadBadge: View {
    let videoId: String

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        switch app.player.downloads.state(of: videoId) {
        case .none:
            EmptyView()
        case .waiting:
            ProgressRing(fraction: 0, size: 14)
        case .downloading(let fraction):
            ProgressRing(fraction: fraction, size: 14)
        case .downloaded:
            IconView(icon: .downloaded, size: 14, colour: theme.textSecondary)
                .accessibilityLabel("Downloaded")
        }
    }
}

struct ProgressRing: View {
    let fraction: Double
    let size: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        let line = size / 7
        ZStack {
            Circle()
                .stroke(theme.ink.opacity(0.15), lineWidth: line)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(theme.accent, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Theme.normal, value: fraction)
        }
        .padding(line / 2)
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(fraction > 0 ? "Downloading, \(Int(fraction * 100)) percent" : "Waiting to download")
    }
}

/// The download buttons' face, the ring just inside the icon.
private struct DownloadStateIcon: View {
    let state: DownloadState
    let size: CGFloat
    let frame: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            switch state {
            case .none: IconView(icon: .download, size: size, colour: theme.textSecondary)
            case .waiting: ProgressRing(fraction: 0, size: size - 2)
            case .downloading(let fraction): ProgressRing(fraction: fraction, size: size - 2)
            case .downloaded: IconView(icon: .downloaded, size: size, colour: theme.accent)
            }
        }
        .frame(width: frame, height: frame)
        .contentShape(Circle())
    }
}

struct DownloadButton: View {
    let route: Route
    let page: Page

    @Environment(AppModel.self) private var app
    @State private var confirming = false

    var body: some View {
        let downloads = app.player.downloads
        let state = downloads.state(of: route)
        Button {
            if state == .none {
                Task { await downloads.download(page, from: route) }
            } else {
                confirming = true
            }
        } label: {
            DownloadStateIcon(state: state, size: 28, frame: 48)
        }
        .buttonStyle(PressScale(scale: 0.88, animation: .easeOut(duration: 0.09)))
        .accessibilityLabel(state == .none ? "Download" : "Remove download")
        .confirmationDialog("Remove this download?", isPresented: $confirming, titleVisibility: .visible) {
            Button(state == .downloaded ? "Remove download" : "Stop downloading", role: .destructive) { downloads.remove(route) }
        } message: {
            Text("Songs also downloaded on their own stay.")
        }
    }
}

/// Now Playing's, beside the ratings. It never removes: that is in the menu, so a stray tap can't lose the file.
struct TrackDownloadButton: View {
    let track: Track

    @Environment(AppModel.self) private var app

    var body: some View {
        let downloads = app.player.downloads
        let state = downloads.state(of: track.id)
        Button {
            switch state {
            case .none: downloads.download(track)
            case .waiting, .downloading: app.showToast("Already downloading")
            case .downloaded: app.showToast("Already downloaded")
            }
        } label: {
            DownloadStateIcon(state: state, size: 22, frame: 40)
        }
        .buttonStyle(PressScale(scale: 0.88, animation: .easeOut(duration: 0.09)))
        .accessibilityLabel(label(state))
    }

    private func label(_ state: DownloadState) -> String {
        switch state {
        case .none: "Download"
        case .waiting, .downloading: "Downloading"
        case .downloaded: "Downloaded"
        }
    }
}

/// Remove download is left out while a downloaded album or playlist still holds the song.
struct TrackDownloadItem: View {
    let track: Track

    @Environment(AppModel.self) private var app

    var body: some View {
        let downloads = app.player.downloads
        if downloads.state(of: track.id) == .none {
            Button("Download") { downloads.download(track) }
        } else if downloads.canRemove(track.id) {
            Button("Remove download", role: .destructive) { downloads.remove(track) }
        }
    }
}

struct CardDownloadItem: View {
    let card: Card

    @Environment(AppModel.self) private var app

    var body: some View {
        if let track = card.track {
            TrackDownloadItem(track: track)
        } else if let route = card.route, Downloads.isDownloadable(route) {
            let downloads = app.player.downloads
            if downloads.state(of: route) == .none {
                Button("Download") { Task { await downloads.download(card) } }
            } else {
                Button("Remove download", role: .destructive) { downloads.remove(route) }
            }
        }
    }
}
