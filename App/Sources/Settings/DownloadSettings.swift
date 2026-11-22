import SwiftUI
import YTMCore

struct DownloadSettings: View {
    @Environment(AppModel.self) private var app
    @State private var confirming = false

    var body: some View {
        @Bindable var settings = app.settings
        let downloads = app.player.downloads
        SettingRow(
            label: "Download quality",
            detail: "High downloads 256 kbps Opus with YouTube Premium. Songs downloaded already keep theirs.",
            stacked: true
        ) {
            ChoicePills(
                choices: [(AudioQuality.low, "Low"), (.normal, "Normal"), (.high, "High")],
                selection: $settings.value.downloadQuality
            )
        }
        ToggleRow(
            label: "Download over Wi-Fi only",
            detail: "Downloads wait for Wi-Fi rather than use mobile data or a hotspot.",
            isOn: $settings.value.downloadOnWiFiOnly
        )
        ToggleRow(
            label: "Smart downloads",
            detail: "Keeps songs you play, and more like them, downloaded, picked afresh each day.",
            isOn: $settings.value.smartDownloads
        )
        if settings.value.smartDownloads {
            SettingRow(label: "Smart downloads keep", stacked: true) {
                ChoicePills(choices: [25, 50, 100, 200].map { ($0, "\($0) songs") }, selection: $settings.value.smartDownloadCount)
            }
        }
        SettingRow(label: "Downloads", detail: "\(Formatting.songs(downloads.songCount)), \(downloads.bytes.formatted(.byteCount(style: .file)))") {
            PillButton(title: "Remove all", small: true) { confirming = true }
                .disabled(downloads.isEmpty)
        }
        .confirmationDialog("Remove all downloads?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Remove all", role: .destructive) { downloads.removeAll() }
        }
    }
}
