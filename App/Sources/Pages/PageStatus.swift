import SwiftUI
import YTMCore

/// Loading, failing and empty pages. The last two are iOS's own empty state,
/// with a symbol, a title and what to do next.
struct PageStatus: View {
    enum Phase {
        case loading(Route)
        case failed(message: String, retry: () -> Void)
        case empty(title: String, symbol: String, message: String)
    }

    let phase: Phase
    /// The route's tint, as `Theme.routeTint` gives it.
    let tint: RGB?

    @Environment(AppModel.self) private var app

    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            switch phase {
            case .loading(let route):
                PageSkeleton(route: route)
            case .failed(let message, let retry):
                ContentUnavailableView {
                    Label(offline ? "You're offline" : "Couldn't load this", systemImage: offline ? "wifi.slash" : "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    PillButton(title: "Try Again", primary: true, action: retry)
                    // Offline, as in YouTube Music, it points to the downloads.
                    if offline, !app.player.downloads.isEmpty {
                        PillButton(title: "Go to Downloads") { app.open(.downloads) }
                    }
                }
            case .empty(let title, let symbol, let message):
                ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) {
            PageTint(colour: tint, top: 0)
                .ignoresSafeArea(edges: .top)
        }
        .background(theme.panel)
    }

    private var offline: Bool {
        app.player.downloads.online == false
    }
}
