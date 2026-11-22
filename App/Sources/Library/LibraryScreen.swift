import SwiftUI
import YTMCore

struct LibraryScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.isSignedIn {
                PageScreen(route: .library)
            } else {
                BringYourLibrary()
            }
        }
        // In the toolbar, so downloads stay reachable offline when the library page can't load.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { app.open(.downloads) } label: { Image(icon: .downloaded) }
                    .accessibilityLabel("Downloads")
            }
        }
    }
}

private struct BringYourLibrary: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        ContentUnavailableView {
            Label("Bring Your Library", systemImage: "music.note.square.stack")
        } description: {
            Text("Sign in to see your playlists, albums and listening history here.")
        } actions: {
            PillButton(title: "Sign In", primary: true) { app.sheet = .signIn }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) {
            PageTint(colour: Theme.routeTint(.library), top: 0)
                .ignoresSafeArea(edges: .top)
        }
        .background(theme.panel)
    }
}
