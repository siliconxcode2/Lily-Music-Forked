import SwiftUI

struct AccountButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Button { app.sheet = .settings } label: {
            AccountPhoto(size: 26)
        }
        .accessibilityLabel("Settings")
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
