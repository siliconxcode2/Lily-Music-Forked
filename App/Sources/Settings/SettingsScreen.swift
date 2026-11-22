import SwiftUI

/// iOS's own settings layout: a grouped list with the account at the top, each
/// area a page of its own, and every explanation in its section's footer.
struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink(value: SettingsPage.account) { AccountSummary() }
                }
                Section {
                    link(.playback, "Playback", symbol: "play.circle.fill")
                    link(.sound, "Sound", symbol: "speaker.wave.2.fill")
                    link(.downloads, "Downloads", symbol: "arrow.down.circle.fill")
                    link(.appearance, "Appearance", symbol: "paintbrush.fill")
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .account: AccountSettings()
                case .playback: PlaybackSettings()
                case .sound: SoundSettings()
                case .downloads: DownloadSettings()
                case .appearance: AppearanceSettings()
                case .equaliser: EqualiserScreen()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .tint(theme.text)
                }
            }
        }
    }

    private func link(_ page: SettingsPage, _ title: String, symbol: String) -> some View {
        NavigationLink(value: page) {
            Label(title, systemImage: symbol)
        }
    }
}

enum SettingsPage: Hashable {
    case account, playback, sound, downloads, appearance, equaliser
}

/// The account's photo and name, as iOS's own Settings opens with.
private struct AccountSummary: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 14) {
            AccountPhoto(size: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.isSignedIn ? app.account?.name ?? "Signed in" : "Sign in")
                    .font(.title3.weight(.semibold))
                Text(app.isSignedIn ? "YouTube account, Last.fm and proxy" : "Your YouTube library, history and Premium")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
