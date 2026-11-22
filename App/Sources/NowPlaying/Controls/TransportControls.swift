import SwiftUI
import YTMCore

struct TransportControls: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let player = app.player
        let settings = app.settings.value
        HStack {
            IconButton(
                icon: settings.shuffle == .smart ? .sparkle : .shuffle, size: 48, iconSize: 22,
                active: settings.shuffle != .off
            ) { player.cycleShuffle() }
            .accessibilityLabel(shuffleLabel(settings.shuffle))
            Spacer()
            IconButton(icon: .previous, size: 56, iconSize: 34, colour: theme.text) { player.previous() }
                .accessibilityLabel("Previous")
            Spacer()
            PlayPauseButton(size: 68)
            Spacer()
            IconButton(icon: .next, size: 56, iconSize: 34, colour: theme.text) { player.next() }
                .accessibilityLabel("Next")
            Spacer()
            IconButton(
                icon: settings.repeatMode == .one ? .repeatOne : .repeat, size: 48, iconSize: 22,
                active: settings.repeatMode != .off
            ) { player.cycleRepeat() }
            .accessibilityLabel(repeatLabel(settings.repeatMode))
        }
        .padding(.vertical, 8)
    }

    private func shuffleLabel(_ mode: ShuffleMode) -> String {
        switch mode {
        case .off: "Shuffle off"
        case .on: "Shuffle on"
        case .smart: "Smart Shuffle"
        }
    }

    private func repeatLabel(_ mode: RepeatMode) -> String {
        switch mode {
        case .off: "Repeat off"
        case .all: "Repeat all"
        case .one: "Repeat one"
        }
    }
}
