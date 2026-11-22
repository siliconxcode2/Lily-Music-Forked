import SwiftUI

/// A view of its own, so play and pause redraw this alone.
struct PlayPauseButton: View {
    let size: CGFloat

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let player = app.player
        ZStack {
            if player.isBuffering {
                Spinner(size: size * 0.78)
            } else {
                PlayButton(size: size, playing: player.isPlaying, colour: theme.text, iconColour: theme.textInverse) {
                    player.togglePlayPause()
                }
            }
        }
        .frame(width: size, height: size)
    }
}
