import SwiftUI
import YTMCore

/// The mini player is the app's own since the tab bar accessory is too short to
/// reach comfortably; each tab has one, so the zoom sources never share an ID.
struct TabRoot<Content: View>: View {
    let tab: AppTab
    let transition: Namespace.ID
    let content: Content

    @Environment(AppModel.self) private var app

    init(tab: AppTab, transition: Namespace.ID, @ViewBuilder content: () -> Content) {
        self.tab = tab
        self.transition = transition
        self.content = content()
    }

    var body: some View {
        @Bindable var navigation = app.navigation(for: tab)
        NavigationStack(path: $navigation.routes) {
            content
                .modifier(MiniPlayerRoom(tab: tab))
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { AccountButton() }
                }
                .navigationDestination(for: Route.self) { route in
                    Group {
                        if route == .downloads { DownloadsScreen() } else { PageScreen(route: route) }
                    }
                    .modifier(MiniPlayerRoom(tab: tab))
                }
        }
        .overlay(alignment: .bottom) { ToastView() }
        // Keeps the toast clear of the capsule; the pages keep their own room (`MiniPlayerRoom`).
        .safeAreaInset(edge: .bottom) {
            MiniPlayer(tab: tab, transition: transition)
        }
    }
}

/// The stack's inset doesn't reach the pages' scroll views, so each page keeps
/// the mini player's room itself, or its last rows sit under it out of reach.
private struct MiniPlayerRoom: ViewModifier {
    let tab: AppTab

    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: MiniPlayer.shown(on: tab, in: app) ? MiniPlayer.room : 0)
        }
    }
}
