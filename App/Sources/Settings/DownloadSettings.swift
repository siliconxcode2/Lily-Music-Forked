import SwiftUI
import YTMCore

struct DownloadSettings: View {
    @Environment(AppModel.self) private var app
    @State private var confirming = false

    var body: some View {
        @Bindable var settings = app.settings
        let downloads = app.player.downloads
        Form {
            Section {
                Picker("Download quality", selection: $settings.value.downloadQuality) {
                    Text("Low").tag(AudioQuality.low)
                    Text("Normal").tag(AudioQuality.normal)
                    Text("High").tag(AudioQuality.high)
                }
            } footer: {
                Text("High downloads 256 kbps Opus with YouTube Premium. Songs downloaded already keep theirs.")
            }
            Section {
                Toggle(isOn: $settings.value.downloadOnWiFiOnly) {
                    Text("Download over Wi-Fi only")
                    Text("Downloads wait for Wi-Fi rather than use mobile data or a hotspot.")
                }
                Toggle(isOn: $settings.value.smartDownloads) {
                    Text("Smart downloads")
                    Text("Keeps songs you play, and more like them, downloaded, picked afresh each day.")
                }
                if settings.value.smartDownloads {
                    Picker("Keep", selection: $settings.value.smartDownloadCount) {
                        ForEach([25, 50, 100, 200], id: \.self) { count in
                            Text("\(count) songs").tag(count)
                        }
                    }
                }
            }
            Section {
                LabeledContent("Downloaded") {
                    Text("\(Formatting.songs(downloads.songCount)), \(downloads.bytes.formatted(.byteCount(style: .file)))")
                        .contentTransition(.numericText())
                        .animation(Theme.fast, value: downloads.bytes)
                }
                Button("Remove All Downloads", role: .destructive) { confirming = true }
                    .disabled(downloads.isEmpty)
            }
        }
        .animation(Theme.normal, value: settings.value.smartDownloads)
        .navigationTitle("Downloads")
        .confirmationDialog("Remove all downloads?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) { downloads.removeAll() }
        }
    }
}
