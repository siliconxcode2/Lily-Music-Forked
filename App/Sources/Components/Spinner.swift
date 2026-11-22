import SwiftUI

struct Spinner: View {
    let size: CGFloat

    @Environment(\.theme) private var theme

    /// The circle's share of the spinner: radius 10 on a 24-unit grid.
    private static let circle: CGFloat = 20 / 24

    var body: some View {
        let line = size / 12
        // 60 a second, as the arc looks no smoother at the display's 120,
        // and it often runs while Now Playing animates.
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let breath = 0.5 - 0.5 * cos(t.truncatingRemainder(dividingBy: 1.4) / 1.4 * 2 * .pi)
            let spin = t.truncatingRemainder(dividingBy: 1.1) / 1.1 * 360 + breath * 120
            ZStack {
                Circle()
                    .stroke(theme.ink.opacity(0.12), lineWidth: line)
                Circle()
                    .trim(from: 0, to: (30 + 240 * breath) / 360)
                    .stroke(theme.accent, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    // The arc starts at the top, as the path's first point is.
                    .rotationEffect(.degrees(spin - 90))
            }
            .frame(width: size * Self.circle, height: size * Self.circle)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Loading")
    }
}
