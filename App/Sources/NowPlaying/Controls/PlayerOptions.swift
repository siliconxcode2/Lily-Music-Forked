import AVKit
import SwiftUI
import YTMCore

struct PlayerOptions: View {
    let open: (PanelTab) -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 4) {
            VolumeControl()
            HStack(spacing: 4) {
                if let stream = app.player.stream {
                    QualityBadge(stream: stream)
                }
                Spacer()
                AirPlayButton()
                opener(.lyrics, icon: .lyrics, label: "Lyrics")
                opener(.upNext, icon: .queue, label: "Up next")
            }
        }
    }

    private func opener(_ tab: PanelTab, icon: Icon, label: String) -> some View {
        IconButton(icon: icon, size: 44, iconSize: 22) { open(tab) }
            .accessibilityLabel(label)
    }
}

private struct VolumeControl: View {
    @Environment(AppModel.self) private var app
    @State private var volume = SystemVolume()

    var body: some View {
        let player = app.player
        let muted = app.settings.value.muted
        HStack(spacing: 8) {
            IconButton(icon: icon(muted: muted), size: 36, iconSize: 20, feedback: .selection) { player.toggleMute() }
                .accessibilityLabel(muted ? "Unmute" : "Mute")
            BarSlider(value: muted ? 0 : Double(volume.level), changed: setVolume, committed: setVolume)
                .accessibilityLabel("Volume")
                .background { SystemVolumeView(volume: volume).frame(width: 1, height: 1).accessibilityHidden(true) }
        }
    }

    private func icon(muted: Bool) -> Icon {
        if muted || volume.level == 0 { return .volumeOff }
        return volume.level < 0.5 ? .volumeLow : .volume
    }

    /// Moving the slider unmutes, as it would on a muted phone.
    private func setVolume(_ value: Double) {
        if app.settings.value.muted { app.player.toggleMute() }
        volume.set(Float(value))
    }
}

/// iOS's own output picker, for AirPlay, Bluetooth and the rest, as Apple Music's beside its lyrics.
private struct AirPlayButton: View {
    @Environment(\.theme) private var theme

    var body: some View {
        RoutePicker(tint: UIColor(theme.textSecondary), active: UIColor(theme.accent))
            .frame(width: IconButton.minimum, height: IconButton.minimum)
    }
}

private struct RoutePicker: UIViewRepresentable {
    let tint: UIColor
    let active: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {
        picker.tintColor = tint
        picker.activeTintColor = active
    }
}
