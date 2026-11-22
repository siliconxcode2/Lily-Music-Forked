import SwiftUI
import YTMAudio
import YTMCore

struct PlaybackSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Picker("Audio Quality", selection: $settings.value.quality) {
                    Text("Low").tag(AudioQuality.low)
                    Text("Normal").tag(AudioQuality.normal)
                    Text("High").tag(AudioQuality.high)
                }
            } footer: {
                Text(qualityDetail(settings.value.quality))
            }
            Section {
                Picker("Speed", selection: $settings.value.speed) {
                    ForEach(Settings.speeds, id: \.self) { speed in
                        Text("\(speed.formatted())×").tag(speed)
                    }
                }
            } footer: {
                Text("Faster or slower, the pitch moving with it as on a record.")
            }
            Section {
                Toggle("Crossfade", isOn: $settings.value.crossfade)
                if settings.value.crossfade {
                    Picker("Length", selection: $settings.value.crossfadeSeconds) {
                        ForEach(Settings.crossfadeLengths, id: \.self) { seconds in
                            Text("\(seconds.formatted()) s").tag(seconds)
                        }
                    }
                }
            } footer: {
                Text("Fades each track into the next. Tracks of an album played in order still run straight on.")
            }
            Section {
                Toggle(isOn: $settings.value.pauseOnUnplug) {
                    Text("Pause When Unplugged")
                    Text("Pauses when headphones or the device playing are unplugged, rather than carrying on through another.")
                }
                Toggle(isOn: $settings.value.autoplay) {
                    Text("Autoplay")
                    Text("Keeps playing similar music when the queue ends.")
                }
                if app.hasHinge {
                    Toggle(isOn: $settings.value.foldToScrub) {
                        Text("Fold to Scrub")
                        Text("With Now Playing open and the phone half open like a book, rest it a moment, then fold it to skip back or open it to skip ahead, 10 seconds a step.")
                    }
                }
            }
            StorageSection()
        }
        .animation(Theme.normal, value: settings.value.crossfade)
        .navigationTitle("Playback")
    }

    private func qualityDetail(_ quality: AudioQuality) -> String {
        switch quality {
        case .low: "About 50 kbps, a third of the data of Normal. For a metered connection."
        case .normal: "About 130 kbps, as YouTube Music plays without Premium."
        case .high: app.player.premiumStatus.summary
        }
    }
}

private struct StorageSection: View {
    @Environment(AppModel.self) private var app
    @State private var size: Int64?

    var body: some View {
        Section {
            LabeledContent("Audio Cache", value: size.map { $0.formatted(.byteCount(style: .file)) } ?? "…")
            Button("Clear Audio Cache", role: .destructive) {
                Task {
                    await app.audio.clearCache()
                    size = await app.audio.cacheSizeBytes
                }
            }
            .disabled(size == 0)
        } footer: {
            Text("Songs played lately, kept so they play again without the network.")
        }
        .task { size = await app.audio.cacheSizeBytes }
    }
}
