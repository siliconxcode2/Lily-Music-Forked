import SwiftUI
import YTMCore

/// The position is pulled four times a second, as the player ticks, never
/// while paused or dragged; a drag seeks once let go.
struct Scrubber: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    /// Where the bar is being dragged to, as a fraction of the song.
    @State private var scrubbing: Double?

    var body: some View {
        let player = app.player
        let length = player.duration
        let total = Formatting.duration(Int(length))
        Playhead(interval: 0.25, held: scrubbing != nil) { time in
            let position = scrubbing.map { $0 * length } ?? time
            let played = Formatting.duration(Int(position))
            VStack(spacing: 0) {
                BarSlider(
                    value: length > 0 ? position / length : 0,
                    buffered: player.bufferedFraction,
                    valueText: "\(played) of \(total)",
                    changed: { scrubbing = $0 }
                ) { fraction in
                    player.seek(to: fraction * length)
                    scrubbing = nil
                }
                .disabled(length <= 0)
                .accessibilityLabel("Position")
                HStack {
                    Text(played)
                    Spacer()
                    Text(total)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.textSecondary)
                .accessibilityHidden(true)
            }
        }
    }
}
