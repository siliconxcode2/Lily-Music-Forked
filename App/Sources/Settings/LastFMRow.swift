import SwiftUI
import YTMCore

/// The app, not this row, waits while access is allowed on Last.fm's page, so
/// leaving Settings doesn't stop it. A build without the API keys has no button.
struct LastFMRow: View {
    private enum Phase: Equatable {
        /// Reading the Keychain.
        case reading
        case unavailable
        case signedOut
        case connected(String)
    }

    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var phase = LastFM.isAvailable ? Phase.reading : .unavailable

    var body: some View {
        SettingRow(label: "Last.fm", detail: detail) { control }
            // Read again as a wait starts or ends, which it may do while the
            // row is gone.
            .task(id: app.isConnectingLastFM) { await refresh() }
    }

    private var detail: String {
        if app.isConnectingLastFM { return "Allow access on the Last.fm page in your browser." }
        return switch phase {
        case .unavailable: "Not available in this build."
        case .reading, .signedOut: "Logs what you play to your Last.fm profile."
        case .connected(let name): "Scrobbling what you play as \(name)."
        }
    }

    @ViewBuilder
    private var control: some View {
        if app.isConnectingLastFM {
            PillButton(title: "Cancel", small: true) { app.cancelLastFMConnect() }
        } else {
            switch phase {
            case .reading, .unavailable:
                EmptyView()
            case .signedOut:
                PillButton(title: "Connect", small: true) { app.connectLastFM(open: openURL) }
            case .connected:
                PillButton(title: "Disconnect", small: true) {
                    Task {
                        await LastFM.shared.signOut()
                        await refresh()
                    }
                }
            }
        }
    }

    private func refresh() async {
        guard phase != .unavailable else { return }
        phase = await LastFM.shared.username.map(Phase.connected) ?? .signedOut
    }
}
