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
            .contentTransition(.symbolEffect(.replace))
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
    let action: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    /// The symbol grows with the reader's text size, as far as half again.
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1

    var body: some View {
        let edge = max(size, Self.minimum)
        Button(action: action) {
            ZStack {
                IconView(icon: icon, size: iconSize * min(textScale, 1.5), colour: iconColour)
                if active {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 4, height: 4)
                        .offset(y: iconSize / 2 + 4)
                }
            }
            .frame(width: edge, height: edge)
            .contentShape(Circle())
        }
        .buttonStyle(PressScale(scale: 0.88, animation: .easeOut(duration: 0.09)))
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var iconColour: Color {
        if !isEnabled { return theme.ink.opacity(0.25) }
        return active ? theme.accent : colour ?? theme.textSecondary
    }
}

struct PlayButton: View {
    var size: CGFloat = 56
    var playing = false
    var colour: Color?
    var iconColour: Color?
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(colour ?? theme.accent)
                .shadow(color: theme.shadow, radius: 6, y: 4)
                .overlay {
                    IconView(icon: playing ? .pause : .play, size: size * 0.48, colour: iconColour ?? theme.onColour)
                }
                .frame(width: size, height: size)
        }
        .buttonStyle(PressScale(scale: 0.95))
        .accessibilityLabel(playing ? "Pause" : "Play")
    }
}

struct PillButton: View {
    let title: String
    var primary = false
    var small = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PillLabel(title: title, primary: primary, small: small)
                // Taller to touch than to see.
                .padding(.vertical, small ? 6 : 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.96))
    }
}

/// A `PillButton`'s look, for links and menus that open something rather than act.
struct PillLabel: View {
    let title: String
    var primary = false
    var small = false

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Text(title)
            .font((small ? Font.footnote : .subheadline).weight(.bold))
            .foregroundStyle(primary ? theme.textInverse : theme.text)
            // A pill is one line: a row squeezes its description instead.
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, small ? 16 : 24)
            .frame(minHeight: small ? 32 : 40)
            .background {
                if primary {
                    Capsule().fill(theme.text)
                } else {
                    Capsule().strokeBorder(theme.ink.opacity(0.44), lineWidth: 1)
                }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct Pill: View {
    let title: String
    let active: Bool
    var compact = false
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font((compact ? Font.footnote : .subheadline).weight(.semibold))
                .foregroundStyle(active ? theme.textInverse : theme.text)
                .lineLimit(1)
                .padding(.horizontal, compact ? 10 : 14)
                .frame(minHeight: 32)
                .background(Capsule().fill(active ? theme.text : theme.hover))
                // Taller to touch than to see, so the row stays slim.
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.96))
        .accessibilityAddTraits(active ? .isSelected : [])
        .animation(Theme.fast, value: active)
    }
}

struct PillGroup: View {
    let titles: [String]
    @Binding var selection: Int

    /// Tighter pills only when the row won't fit, and scrolling only when even those won't, so no title is cut
    /// short.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            pills(compact: false)
            pills(compact: true)
            // Unclipped, so the row runs on to the screen's edge, and kept on the pill chosen.
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    pills(compact: true)
                }
                .scrollClipDisabled()
                .onAppear { scroller.scrollTo(selection) }
                .onChange(of: selection) { withAnimation(Theme.fast) { scroller.scrollTo(selection) } }
            }
        }
    }

    private func pills(compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 6) {
            ForEach(titles.indices, id: \.self) { index in
                Pill(title: titles[index], active: selection == index, compact: compact) { selection = index }
            }
        }
    }
}

struct PressScale: ButtonStyle {
    var scale: CGFloat
    var animation = Theme.fast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(animation, value: configuration.isPressed)
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
