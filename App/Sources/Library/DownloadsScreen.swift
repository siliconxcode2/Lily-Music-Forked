import SwiftUI
import YTMCore

/// Built from what the phone holds, so it opens offline.
struct DownloadsScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let page = app.player.downloads.page {
            PageContent(page: page, route: .downloads)
        } else {
            PageStatus(phase: .empty(title: "No Downloads", symbol: "arrow.down.circle", message: "Songs, albums and playlists you download show up here."), tint: Theme.routeTint(.downloads))
                .navigationTitle("Downloads")
        }
    }
}
