import SwiftUI

/// A symbol in a `size`-point square. A symbol drawn at a font size fills about
/// four fifths of it, as the old 24-point icons filled their grid.
struct IconView: View {
    let icon: Icon
    var size: CGFloat = 24
    let colour: Color

    var body: some View {
        Image(icon: icon)
            .font(.system(size: size * 0.8))
            .foregroundStyle(colour)
            // One symbol turns into the next, as play into pause, rather than swapping.
            .contentTransition(.symbolEffect(.replace))
            .animation(Theme.fast, value: icon)
            .frame(width: size, height: size)
    }
}

/// Never laid out smaller than 44 points, the least HIG allows a finger.
struct IconButton: View {
    static let minimum: CGFloat = 44

    let icon: Icon
    var size: CGFloat = 44
    var iconSize: CGFloat = 18
    var active = false
    /// The theme's secondary text when nil.
    var colour: Color?
    /// On a clear glass circle, for buttons that float over content rather than sit in a bar.
    var glass = false
    /// Felt with each tap, for the controls whose effect is heard rather than seen.
    var feedback: SensoryFeedback?
    let action: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var taps = 0
    /// The symbol grows with the reader's text size, as far as half again.
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1

    var body: some View {
        let edge = max(size, Self.minimum)
        Button {
            taps += 1
            action()
        } label: {
            ZStack {
                IconView(icon: icon, size: iconSize * min(textScale, 1.5), colour: iconColour)
                    // A tap is answered by the symbol itself.
                    .symbolEffect(.bounce, value: taps)
                if active {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 4, height: 4)
                        .offset(y: iconSize / 2 + 4)
                }
            }
            .frame(width: edge, height: edge)
            .contentShape(Circle())
            .glassEffect(glass ? .regular.interactive() : .identity, in: Circle())
        }
        // Glass answers a touch itself, so it isn't shrunk as well.
        .buttonStyle(PressScale(scale: glass ? 1 : 0.88, animation: Theme.press))
        .sensoryFeedback(trigger: taps) { _, _ in feedback }
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var iconColour: Color {
        if !isEnabled { return theme.ink.opacity(0.25) }
        return active ? theme.accent : colour ?? theme.textSecondary
    }
}

/// A circle of glass tinted the accent, as iOS's prominent glass buttons are.
struct PlayButton: View {
    var size: CGFloat = 56
    var playing = false
    var colour: Color?
    var iconColour: Color?
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            IconView(icon: playing ? .pause : .play, size: size * 0.48, colour: iconColour ?? theme.onColour)
                .symbolEffect(.bounce, value: taps)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .glassEffect(.regular.tint(colour ?? theme.accent).interactive(), in: Circle())
        }
        // Glass answers a touch itself.
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: taps)
        .accessibilityLabel(playing ? "Pause" : "Play")
    }
}

/// iOS's own glass button: prominent, in the accent, for the one thing a screen
/// is for; clear glass for the rest.
struct PillButton: View {
    let title: String
    var primary = false
    var small = false
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        if primary {
            button(foreground: theme.onColour).buttonStyle(.glassProminent)
        } else {
            button(foreground: theme.text).buttonStyle(.glass)
        }
    }

    private func button(foreground: Color) -> some View {
        Button(action: action) {
            Text(title)
                .font((small ? Font.footnote : .subheadline).weight(.semibold))
                .foregroundStyle(foreground)
                // A pill is one line: a row squeezes its description instead.
                .lineLimit(1)
                .fixedSize()
        }
        .controlSize(small ? .small : .regular)
        .buttonBorderShape(.capsule)
    }
}

/// A `PillButton`'s look, for menus and links that open something rather than act.
struct PillLabel: View {
    let title: String
    var primary = false
    var small = false

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Text(title)
            .font((small ? Font.footnote : .subheadline).weight(.semibold))
            .foregroundStyle(primary ? theme.onColour : theme.text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, small ? 14 : 20)
            .frame(minHeight: small ? 32 : 40)
            .glassEffect(primary ? .regular.tint(theme.accent).interactive() : .regular.interactive(), in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Not shrunk with Reduce Motion on, as iOS's own buttons aren't.
struct PressScale: ButtonStyle {
    var scale: CGFloat
    var animation = Theme.press

    func makeBody(configuration: Configuration) -> some View {
        PressScaleBody(configuration: configuration, scale: scale, animation: animation)
    }

    private struct PressScaleBody: View {
        let configuration: Configuration
        let scale: CGFloat
        let animation: Animation

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
                .animation(animation, value: configuration.isPressed)
        }
    }
}

struct RowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowPressBody(configuration: configuration)
    }

    private struct RowPressBody: View {
        let configuration: Configuration
        @Environment(\.theme) private var theme

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? theme.hover : .clear)
                )
                .animation(Theme.fast, value: configuration.isPressed)
        }
    }
}
