import SwiftUI
import YTMAudio
import YTMCore

struct EqualiserScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    static func summary(_ settings: Settings) -> String {
        settings.equaliserEnabled ? preset(matching: settings.equaliserGains) ?? "Custom" : "Off"
    }

    private static func preset(matching gains: [Float]) -> String? {
        EqualiserBands.presets.first { $0.gains == gains }?.name
    }

    var body: some View {
        @Bindable var settings = app.settings
        let gains = settings.value.equaliserGains
        // Scrolling only where ten bands outgrow the screen, as on iPhone Duo's inner display held landscape.
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingRow(label: "Preset", detail: "A starting point; the bands below fine-tune it.") {
                    HStack(spacing: 12) {
                        Menu {
                            ForEach(EqualiserBands.presets.indices, id: \.self) { index in
                                Button(EqualiserBands.presets[index].name) { choose(index) }
                            }
                        } label: {
                            PillLabel(title: Self.preset(matching: gains) ?? "Custom", small: true)
                        }
                        Toggle("Equaliser", isOn: $settings.value.equaliserEnabled)
                            .labelsHidden()
                    }
                }
                // Closer together than the screen's rows, so ten bands fit.
                VStack(spacing: 8) {
                    ForEach(EqualiserBands.frequencies.indices, id: \.self) { band in
                        BandRow(
                            label: Self.label(EqualiserBands.frequencies[band]),
                            gain: gains.indices.contains(band) ? gains[band] : 0,
                            enabled: settings.value.equaliserEnabled
                        ) { set(band, to: $0) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(theme.menu)
        .navigationTitle("Equaliser")
    }

    /// A preset turns the equaliser on too, in one change.
    private func choose(_ index: Int) {
        var value = app.settings.value
        value.equaliserEnabled = true
        value.equaliserGains = EqualiserBands.presets[index].gains
        app.settings.value = value
    }

    /// A drag reports every move, most within the same dB, which change nothing.
    private func set(_ band: Int, to fraction: Double) {
        // Adding 0 turns the -0 just left of centre into 0.
        let gain = ((Float(fraction) * 2 - 1) * EqualiserBands.maxGain).rounded() + 0
        guard app.settings.value.equaliserGains.indices.contains(band),
              app.settings.value.equaliserGains[band] != gain else { return }
        app.settings.value.equaliserGains[band] = gain
    }

    private static func label(_ hz: Float) -> String {
        hz >= 1_000 ? "\((hz / 1_000).formatted()) kHz" : "\(hz.formatted()) Hz"
    }
}

private struct BandRow: View {
    let label: String
    let gain: Float
    let enabled: Bool
    let set: (Double) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 16) {
            Text(label)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 64, alignment: .leading)
            BarSlider(value: Double(gain / EqualiserBands.maxGain + 1) / 2, changed: set, committed: set)
                .disabled(!enabled)
                .accessibilityLabel(label)
            Text("\(gain > 0 ? "+" : "")\(Int(gain.rounded())) dB")
                .monospacedDigit()
                .foregroundStyle(enabled ? theme.text : theme.textDim)
                .frame(width: 48, alignment: .trailing)
        }
        .font(.system(size: 13))
    }
}
