import Network
import SwiftUI
import YTMCore

/// Google's own page signs in and its YouTube Music cookies sign the app in, so
/// the password goes to Google only.
struct SignInScreen: View {
    private enum Phase: Equatable {
        case browsing
        case signingIn
        case failed(String)
    }

    private let onSignedIn: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    /// Leaving `.browsing` drops the page with its private session, so
    /// Try again starts signed out on a fresh one.
    @State private var phase = Phase.browsing
    /// Read before the page loads, so it goes through the user's proxy.
    @State private var proxies: [ProxyConfiguration]?

    init(onSignedIn: @escaping () -> Void) {
        self.onSignedIn = onSignedIn
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.panel)
                .navigationTitle("Sign in")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .browsing:
            ZStack {
                spinner
                if let proxies {
                    SignInWebView(onSession: signIn, onFailure: { phase = .failed($0) }, proxies: proxies)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .task { proxies = await Self.proxiesInUse() }
        case .signingIn:
            spinner
        case .failed(let message):
            VStack(spacing: 20) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(theme.signInError)
                    .multilineTextAlignment(.center)
                PillButton(title: "Try again", primary: true) { phase = .browsing }
            }
            .padding(24)
        }
    }

    private var spinner: some View {
        ProgressView()
            .controlSize(.large)
            .tint(theme.accent)
    }

    /// Off the main actor, as the first read touches the Keychain.
    @concurrent
    private static func proxiesInUse() async -> [ProxyConfiguration] {
        Proxy.configurations
    }

    private func signIn(with cookies: [HTTPCookie]) {
        // Later pages of the same session hand over again.
        guard phase == .browsing else { return }
        phase = .signingIn
        Task {
            do {
                try await GoogleAuth.shared.signIn(cookies: cookies)
                onSignedIn()
                dismiss()
            } catch {
                phase = .failed(sentence(for: error))
            }
        }
    }
}

private extension Theme {
    var signInError: Color {
        Color(rgb: RGB(hex: isLight ? 0xc4002b : 0xff6b81))
    }
}
