import SwiftUI
import YTMAudio
import YTMCore

struct EqualiserScreen: View {
    @Environment(AppModel.self) private var app

    static func summary(_ settings: Settings) -> String {
        settings.equaliserEnabled ? preset(matching: settings.equaliserGains) ?? "Custom" : "Off"
    }

    private static func preset(matching gains: [Float]) -> String? {
        EqualiserBands.presets.first { $0.gains == gains }?.name
    }

    var body: some View {
        @Bindable var settings = app.settings
        let gains = settings.value.equaliserGains
        Form {
            Section {
                Toggle("Equaliser", isOn: $settings.value.equaliserEnabled)
                Picker("Preset", selection: presetBinding) {
                    if Self.preset(matching: gains) == nil {
                        Text("Custom").tag(-1)
                    }
                    ForEach(EqualiserBands.presets.indices, id: \.self) { index in
                        Text(EqualiserBands.presets[index].name).tag(index)
                    }
                }
            } footer: {
                Text("A preset is a starting point; the bands below fine-tune it.")
            }
            Section("Bands") {
                ForEach(EqualiserBands.frequencies.indices, id: \.self) { band in
                    BandRow(
                        label: Self.label(EqualiserBands.frequencies[band]),
                        gain: gains.indices.contains(band) ? gains[band] : 0,
                        enabled: settings.value.equaliserEnabled
                    ) { set(band, to: $0) }
                }
            }
        }
        .navigationTitle("Equaliser")
    }

    /// The preset the bands match, or -1 for Custom.
    private var presetBinding: Binding<Int> {
        Binding {
            EqualiserBands.presets.firstIndex { $0.gains == app.settings.value.equaliserGains } ?? -1
        } set: { index in
            if EqualiserBands.presets.indices.contains(index) { choose(index) }
        }
    }

    /// A preset turns the equaliser on too, in one change.
    private func choose(_ index: Int) {
        var value = app.settings.value
        value.equaliserEnabled = true
        value.equaliserGains = EqualiserBands.presets[index].gains
        app.settings.value = value
    }

    /// A drag reports every move, most within the same dB, which change nothing.
    private func set(_ band: Int, to value: Float) {
        // Adding 0 turns the -0 just left of centre into 0.
        let gain = value.rounded() + 0
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
    let set: (Float) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .leading)
            Slider(value: Binding { gain } set: { set($0) }, in: -EqualiserBands.maxGain...EqualiserBands.maxGain, step: 1)
                .disabled(!enabled)
                .accessibilityLabel(label)
                .accessibilityValue("\(Int(gain.rounded())) decibels")
            Text("\(gain > 0 ? "+" : "")\(Int(gain.rounded())) dB")
                .monospacedDigit()
                .foregroundStyle(enabled ? .primary : .tertiary)
                .frame(minWidth: 48, alignment: .trailing)
        }
        .font(.footnote)
    }
}
