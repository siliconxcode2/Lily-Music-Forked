import SwiftUI
import YTMCore

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Namespace private var transition

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.tab) {
            Tab(value: AppTab.home) {
                TabRoot(tab: .home, transition: transition) { PageScreen(route: .home) }
            } label: {
                TabLabel(title: "Home", icon: app.tab == .home ? .home : .homeOutline)
            }
            Tab(value: AppTab.explore) {
                TabRoot(tab: .explore, transition: transition) { PageScreen(route: .explore) }
            } label: {
                TabLabel(title: "Explore", icon: .explore)
            }
            Tab(value: AppTab.library) {
                TabRoot(tab: .library, transition: transition) { LibraryScreen() }
            } label: {
                TabLabel(title: "Library", icon: .library)
            }
            Tab(value: AppTab.history) {
                TabRoot(tab: .history, transition: transition) { HistoryScreen() }
            } label: {
                TabLabel(title: "History", icon: .history)
            }
            Tab(value: AppTab.search, role: .search) {
                TabRoot(tab: .search, transition: transition) { SearchScreen() }
            }
        }
        // The bar shrinks as a page scrolls down, giving the page the screen, and the mini player moves in beside it.
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(MiniPlayerAccessory(transition: transition))
        .sheet(item: presented { $0 != .nowPlaying }) { sheet in
            SheetContent(sheet: sheet, transition: transition)
        }
        // Full screen rather than a sheet, so a swipe down is the zoom's own
        // close rather than the sheet sliding away and then zooming.
        .fullScreenCover(item: presented { $0 == .nowPlaying }) { sheet in
            SheetContent(sheet: sheet, transition: transition)
        }
        .environment(\.theme, app.theme)
        .preferredColorScheme(app.theme.colorScheme)
        .tint(app.theme.accent)
        .task { await app.followTheme() }
        .task { await app.followPinned() }
        .modifier(FollowPlayer())
        .modifier(HingeCheck())
    }

    private func presented(_ shows: @escaping (AppSheet) -> Bool) -> Binding<AppSheet?> {
        Binding {
            app.sheet.flatMap { shows($0) ? $0 : nil }
        } set: { sheet in
            if sheet == nil, let current = app.sheet, shows(current) { app.sheet = nil }
        }
    }
}

/// Apart from RootView, so a song change re-runs this rather than the whole tab tree.
private struct FollowPlayer: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content
            .task(id: app.player.current?.thumbnail) { await app.followArtwork(of: app.player.current?.thumbnail) }
            .onChange(of: app.player.libraryRevision) { app.libraryChanged() }
            .onChange(of: app.player.downloads.isActive) { _, active in app.keepDownloading(active) }
    }
}

private struct TabLabel: View {
    let title: String
    let icon: Icon

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(icon: icon)
        }
    }
}

/// Each with the toast over it, since a sheet covers the tabs' own.
private struct SheetContent: View {
    let sheet: AppSheet
    let transition: Namespace.ID

    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch sheet {
            case .nowPlaying:
                NowPlayingScreen()
                    .navigationTransition(.zoom(sourceID: MiniPlayerAccessory.zoomSource(tab: app.tab), in: transition))
            case .settings:
                SettingsScreen()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            case .signIn:
                // Full height, as Google's sign-in page needs the room.
                SignInScreen { Task { await app.accountChanged() } }
                    .presentationDetents([.large])
            case .addToPlaylist(let track):
                PlaylistPickerSheet(track: track)
            }
        }
        .overlay(alignment: .bottom) { ToastView() }
    }
}
