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
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Bring your library")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.text)
                Text("Sign in to see your playlists, albums and listening history here.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                PillButton(title: "Sign in", primary: true, small: true) { app.sheet = .signIn }
                    .padding(.top, 6)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(theme.elevated))
            .padding(Metrics.pagePadding)
        }
        .background(alignment: .top) {
            PageTint(colour: Theme.routeTint(.library), top: 0)
                .ignoresSafeArea(edges: .top)
        }
        .background(theme.panel)
    }
}
