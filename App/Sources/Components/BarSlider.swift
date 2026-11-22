import SwiftUI

/// Driven from outside: `changed` follows the finger, `committed` takes where it was let go, and
/// the owner passes the value back.
struct BarSlider: View {
    /// From 0 to 1.
    let value: Double
    /// From 0 to 1, drawn lighter behind `value`.
    var buffered = 0.0
    /// Read by VoiceOver in place of the percentage.
    var valueText: String?
    let changed: (Double) -> Void
    let committed: (Double) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var width: CGFloat = 0
    @State private var dragging = false
    /// Whether a finger is on the bar; reset by SwiftUI when a scroll around
    /// the bar takes the touch over, which never ends the drag.
    @GestureState private var touching = false

    private static let touchHeight: CGFloat = 44
    private static let barHeight: CGFloat = 4
    private static let knob: CGFloat = 12
    /// One swipe of VoiceOver's adjust.
    private static let step = 0.05

    var body: some View {
        let shown = min(max(value, 0), 1)
        ZStack(alignment: .leading) {
            Capsule()
                .fill(theme.ink.opacity(0.19))
            Capsule()
                .fill(theme.ink.opacity(0.16))
                .scaleEffect(x: min(max(buffered, 0), 1), anchor: .leading)
            Capsule()
                .fill(dragging ? theme.accent : theme.text)
                // Scaled rather than resized, so a moving bar never lays out.
                .scaleEffect(x: shown, anchor: .leading)
        }
        .frame(height: Self.barHeight)
        // So a slider that does nothing doesn't look as if it would.
        .opacity(isEnabled ? 1 : 0.4)
        .animation(Theme.fast, value: isEnabled)
        .overlay(alignment: .leading) {
            Circle()
                .fill(theme.text)
                .shadow(color: theme.shadow, radius: 2)
                .frame(width: Self.knob, height: Self.knob)
                .offset(x: width * shown - Self.knob / 2)
                .opacity(dragging ? 1 : 0)
        }
        .animation(Theme.fast, value: dragging)
        .frame(maxWidth: .infinity, minHeight: Self.touchHeight)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        .gesture(drag, isEnabled: isEnabled)
        // A drag taken over by a scroll is let go where it was, so the bar
        // and its owner never stay mid-drag.
        .onChange(of: touching) { _, touching in
            guard !touching, dragging else { return }
            dragging = false
            committed(shown)
        }
        .accessibilityElement()
        .accessibilityValue(valueText.map { Text($0) } ?? Text(shown, format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: committed(min(shown + Self.step, 1))
            case .decrement: committed(max(shown - Self.step, 0))
            @unknown default: break
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { _, touching, _ in touching = true }
            .onChanged { gesture in
                dragging = true
                changed(fraction(at: gesture.location.x))
            }
            .onEnded { gesture in
                dragging = false
                committed(fraction(at: gesture.location.x))
            }
    }

    private func fraction(at x: CGFloat) -> Double {
        width > 0 ? min(max(x / width, 0), 1) : 0
    }
}
