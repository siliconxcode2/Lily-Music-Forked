import SwiftUI
import YTMCore

struct SoundSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Picker("Normalise Volume", selection: $settings.value.normalise) {
                    Text("Off").tag(Normalise.off)
                    Text("Quiet").tag(Normalise.quiet)
                    Text("Normal").tag(Normalise.normal)
                }
            } footer: {
                Text(Self.normaliseDetail(settings.value.normalise))
            }
            Section {
                NavigationLink(value: SettingsPage.equaliser) {
                    LabeledContent("Equaliser", value: EqualiserScreen.summary(settings.value))
                }
            }
            Section {
                Toggle(isOn: $settings.value.crossfeed) {
                    Text("Crossfeed")
                    Text("For headphones: blends a little of each side into the other, as speakers do.")
                }
                Toggle(isOn: $settings.value.mono) {
                    Text("Mono")
                    Text("Both sides in each ear, for listening with one earbud.")
                }
            }
            Section {
                let balance = Self.balanceDetail(settings.value.balance)
                Slider(value: balanceBinding, in: -1...1) {
                    Text("Balance")
                } minimumValueLabel: {
                    Text("L")
                } maximumValueLabel: {
                    Text("R")
                }
                .accessibilityValue(balance)
            } header: {
                Text("Balance")
            } footer: {
                Text(Self.balanceDetail(settings.value.balance))
            }
        }
        .navigationTitle("Sound")
    }

    /// Whole percents, snapping to centre near the middle. A drag reports every move, most within the same
    /// percent, which change nothing.
    private var balanceBinding: Binding<Float> {
        Binding {
            app.settings.value.balance
        } set: { value in
            let balance = (value * 100).rounded() / 100
            let snapped: Float = abs(balance) < 0.05 ? 0 : balance
            guard app.settings.value.balance != snapped else { return }
            app.settings.value.balance = snapped
        }
    }

    private static func balanceDetail(_ balance: Float) -> String {
        guard balance != 0 else { return "Centre" }
        return "\(balance < 0 ? "Left" : "Right") \(Int((abs(balance) * 100).rounded()))%"
    }

    private static func normaliseDetail(_ normalise: Normalise) -> String {
        switch normalise {
        case .off: "Plays every track as it was mastered, leaving loud ones loud and quiet ones quiet."
        case .quiet: "Plays every track at a similar loudness, a little quieter than Normal."
        case .normal: "Plays every track at a similar loudness, turning quiet ones up and loud ones down."
        }
    }
}
