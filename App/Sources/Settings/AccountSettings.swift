import SwiftUI
import YTMCore

struct AccountSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                HStack(spacing: 14) {
                    AccountPhoto(size: 44)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.isSignedIn ? app.account?.name ?? "Signed in" : "Not signed in")
                            .font(.headline)
                        Text(app.isSignedIn ? "Your library and history come from your YouTube account." : "Sign in to see your library and history.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if app.isSignedIn {
                    Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
                } else {
                    Button("Sign In") { app.sheet = .signIn }
                }
            }
            if app.isSignedIn {
                Section {
                    Toggle(isOn: $settings.value.youtubeHistory) {
                        Text("YouTube history")
                        Text("Adds songs played here to your YouTube Music history, so your recommendations and Listen again reflect them.")
                    }
                    Toggle(isOn: $settings.value.ratingButtons) {
                        Text("Like and dislike buttons")
                        Text("Shows them beside the song playing. Liking adds a song to your Liked music; disliking steers your recommendations away from it.")
                    }
                }
            }
            LastFMSection()
            ProxySection()
        }
        .navigationTitle(app.isSignedIn ? "Account" : "Sign In")
    }
}
