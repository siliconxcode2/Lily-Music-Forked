import SwiftUI

/// Rests low while paused, so a paused row draws nothing.
struct Equalizer: View {
    let active: Bool
    var colour: Color?

    @Environment(\.theme) private var theme
    /// Bars stood still at varied heights, still saying what's playing.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let frame: TimeInterval = 0.125
    private static let size = CGSize(width: 16, height: 14)

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.frame, paused: !active || reduceMotion)) { timeline in
            let phase = reduceMotion ? 1 : (timeline.date.timeIntervalSinceReferenceDate / Self.frame).rounded(.down)
            Canvas { context, size in
                for bar in 0..<3 {
                    let height = active
                        ? size.height * (0.25 + 0.75 * abs(sin((phase * 0.55 + Double(bar) * 0.37) * .pi)))
                        : size.height * 0.3
                    let rect = CGRect(x: CGFloat(bar) * 5.5, y: size.height - height, width: 3, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(colour ?? theme.accent))
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityHidden(true)
    }
}
