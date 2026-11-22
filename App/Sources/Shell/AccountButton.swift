import SwiftUI

struct AccountButton: View {
    let tab: AppTab

    @Environment(AppModel.self) private var app
    @Environment(\.sheetZoom) private var sheetZoom

    var body: some View {
        let button = Button { app.sheet = .settings } label: {
            AccountPhoto(size: 26)
        }
        .accessibilityLabel("Settings")
        if let sheetZoom {
            // Settings grows out of the photo, as iOS 26's sheets grow out of the button that opens them.
            button.matchedTransitionSource(id: SettingsZoomID(tab: tab), in: sheetZoom)
        } else {
            button
        }
    }
}

struct AccountPhoto: View {
    let size: CGFloat

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Circle().fill(app.isSignedIn ? theme.accent : theme.ink.opacity(0.3))
            IconView(icon: .account, size: size * 0.69, colour: app.isSignedIn ? theme.onColour : theme.text)
            if app.isSignedIn, let photo = app.account?.photo {
                ArtworkImage(url: photo, edge: size, placeholder: false)
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
    }
}
