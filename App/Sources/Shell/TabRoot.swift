import SwiftUI
import YTMCore

/// Before iOS 26.1 each tab floats its own mini player, so the zoom sources
/// never share an ID; from then on the tab bar's accessory is the one mini player.
struct TabRoot<Content: View>: View {
    let tab: AppTab
    let transition: Namespace.ID
    let content: Content

    @Environment(AppModel.self) private var app
    /// What cards name themselves in, so the pages they open zoom out of them.
    @Namespace private var cards

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
                // Large, as Apple Music's tabs are, shrinking into the bar as the page scrolls.
                .navigationTitle(tab.title)
                .toolbarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { AccountButton(tab: tab) }
                }
                .navigationDestination(for: Route.self) { route in
                    Group {
                        if route == .downloads { DownloadsScreen() } else { PageScreen(route: route) }
                    }
                    .modifier(MiniPlayerRoom(tab: tab))
                    .zoomsIn(from: route, in: cards)
                }
        }
        .environment(\.cardZoom, cards)
        .overlay(alignment: .bottom) { ToastView() }
        // Keeps the toast clear of the capsule; the pages keep their own room (`MiniPlayerRoom`).
        .safeAreaInset(edge: .bottom) {
            if !MiniPlayerAccessory.isAvailable {
                FloatingMiniPlayer(tab: tab, transition: transition)
            }
        }
    }
}

/// The stack's inset doesn't reach the pages' scroll views, so each page keeps
/// the floating mini player's room itself, or its last rows sit under it out of
/// reach. The accessory's room iOS keeps itself.
private struct MiniPlayerRoom: ViewModifier {
    let tab: AppTab

    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            let floating = !MiniPlayerAccessory.isAvailable && MiniPlayer.shown(on: tab, in: app)
            Color.clear.frame(height: floating ? FloatingMiniPlayer.room : 0)
        }
    }
}

extension AppTab {
    /// The tab's large title. Home greets by the time of day.
    var title: String {
        switch self {
        case .home: Self.greeting(hour: Calendar.current.component(.hour, from: .now))
        case .explore: "Explore"
        case .library: "Library"
        case .history: "History"
        case .search: "Search"
        }
    }

    private static func greeting(hour: Int) -> String {
        switch hour {
        case 4..<12: "Good Morning"
        case 12..<18: "Good Afternoon"
        case 18..<23: "Good Evening"
        default: "Good Night"
        }
    }
}

extension Route {
    /// The page a tab opens on, whose title is the tab's.
    var isTabRoot: Bool {
        switch self {
        case .home, .explore, .library, .history: true
        default: false
        }
    }
}
