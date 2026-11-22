import SwiftUI
import YTMCore

struct SoundSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        SettingRow(
            label: "Normalise volume", detail: Self.normaliseDetail(settings.value.normalise), detailRoom: Self.normaliseDetail(.off),
            stacked: true
        ) {
            ChoicePills(choices: [(Normalise.off, "Off"), (.quiet, "Quiet"), (.normal, "Normal")], selection: $settings.value.normalise)
        }
        SettingRow(label: "Equaliser", detail: EqualiserScreen.summary(settings.value)) {
            NavigationLink(value: SettingsPage.equaliser) {
                PillLabel(title: "Adjust", small: true)
            }
            .buttonStyle(PressScale(scale: 0.96))
        }
        ToggleRow(
            label: "Crossfeed",
            detail: "For headphones: blends a little of each side into the other, as speakers do.",
            isOn: $settings.value.crossfeed
        )
        ToggleRow(label: "Mono", detail: "Both sides in each ear, for listening with one earbud.", isOn: $settings.value.mono)
        let balance = Self.balanceDetail(settings.value.balance)
        SettingRow(label: "Balance", detail: balance) {
            BarSlider(value: Double(settings.value.balance + 1) / 2, valueText: balance, changed: setBalance, committed: setBalance)
                .frame(width: 160)
                .accessibilityLabel("Balance")
        }
    }

    /// Whole percents, snapping to centre near the middle. A drag reports every move, most within the same
    /// percent, which change nothing.
    private func setBalance(_ fraction: Double) {
        let balance = ((Float(fraction) * 2 - 1) * 100).rounded() / 100
        let snapped: Float = abs(balance) < 0.05 ? 0 : balance
        guard app.settings.value.balance != snapped else { return }
        app.settings.value.balance = snapped
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
