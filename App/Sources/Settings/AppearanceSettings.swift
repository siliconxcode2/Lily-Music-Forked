import SwiftUI
import YTMCore

struct AppearanceSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        let accent = settings.value.accent
        Form {
            Section("Theme") {
                Picker("Theme", selection: $settings.value.look) {
                    Text("Match System").tag(Look.system)
                    Text("Black").tag(Look.black)
                    Text("Dark").tag(Look.dark)
                    Text("Light").tag(Look.light)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 4)], spacing: 4) {
                    ForEach(Accent.allCases, id: \.self) { choice in
                        Swatch(accent: choice, active: choice == accent) { settings.value.accent = choice }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Accent colour")
            } footer: {
                Text(accent == .artwork ? "Follows the artwork of the song playing." : accent.name)
            }
        }
        .navigationTitle("Appearance")
    }
}

private struct Swatch: View {
    let accent: Accent
    let active: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme

    private static let size: CGFloat = 44
    private static let fill: CGFloat = 32
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
        .sensoryFeedback(.selection, trigger: active)
        .animation(Theme.fast, value: active)
        .accessibilityLabel(accent.name)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
