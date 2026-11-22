import SwiftUI

struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PillGroup(titles: ["Playback", "Sound", "Downloads", "Appearance", "Account"], selection: $tab)
                    switch tab {
                    case 0: PlaybackSettings()
                    case 1: SoundSettings()
                    case 2: DownloadSettings()
                    case 3: AppearanceSettings()
                    default: AccountSettings()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
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
}

enum SettingsPage: Hashable {
    case equaliser
}
