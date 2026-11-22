import SwiftUI
import YTMCore

struct AppearanceSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        let accent = settings.value.accent
        SettingRow(label: "Theme", stacked: true) {
            ChoicePills(choices: [(Look.dark, "Dark"), (.light, "Light"), (.black, "Black")], selection: $settings.value.look)
        }
        SettingRow(
            label: "Accent colour",
            detail: accent == .artwork ? "Follows the artwork of the song playing." : accent.name,
            stacked: true
        ) {
            HStack(spacing: 6) {
                ForEach(Accent.allCases, id: \.self) { choice in
                    Swatch(accent: choice, active: choice == accent) { settings.value.accent = choice }
                }
            }
        }
    }
}

private struct Swatch: View {
    let accent: Accent
    let active: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme

    private static let size: CGFloat = 34
    private static let fill: CGFloat = 24
    private static let artwork = LinearGradient(
        colors: [Accent.red, .purple, .teal].compactMap(\.rgb).map { Color(rgb: RGB(hex: $0)) },
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(active ? theme.text : .clear, lineWidth: 2)
                Group {
                    if let rgb = accent.rgb {
                        Circle().fill(Color(rgb: RGB(hex: rgb)))
                    } else {
                        Circle().fill(Self.artwork)
                    }
                }
                .frame(width: Self.fill, height: Self.fill)
            }
            .frame(width: Self.size, height: Self.size)
            .contentShape(Circle())
        }
        .buttonStyle(PressScale(scale: 0.9))
        .animation(Theme.fast, value: active)
        .accessibilityLabel(accent.name)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
