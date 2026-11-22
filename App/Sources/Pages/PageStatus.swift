import SwiftUI
import YTMCore

struct PageStatus: View {
    enum Phase {
        case loading(Route)
        case failed(message: String, retry: () -> Void)
        case empty(String)
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
                VStack(spacing: 20) {
                    Message(text: message)
                    PillButton(title: "Try again", primary: true, action: retry)
                    // Offline, as in YouTube Music, it points to the downloads.
                    if app.player.downloads.online == false, !app.player.downloads.isEmpty {
                        PillButton(title: "Go to downloads") { app.open(.downloads) }
                    }
                }
                .padding(48)
            case .empty(let message):
                Message(text: message)
                    .padding(48)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) {
            PageTint(colour: tint, top: 0)
                .ignoresSafeArea(edges: .top)
        }
        .background(theme.panel)
    }

    private struct Message: View {
        let text: String

        @Environment(\.theme) private var theme

        var body: some View {
            Text(text)
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.text)
                .multilineTextAlignment(.center)
        }
    }
}
