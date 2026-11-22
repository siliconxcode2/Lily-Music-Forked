import Network
import SwiftUI
import WebKit
import os

/// Google's sign-in page: private, kept to the sign-in chain, with no new
/// windows or downloads.
struct SignInWebView: UIViewRepresentable {
    /// The cookies sent to YouTube Music, HttpOnly ones included, once a session is among them.
    let onSession: ([HTTPCookie]) -> Void
    /// A sentence for the user when the page can't go on.
    let onFailure: (String) -> Void
    /// The user's own proxy, which the page would otherwise go around for iOS's.
    let proxies: [ProxyConfiguration]

    private static let startURL = URL(
        string: "https://accounts.google.com/ServiceLogin?service=youtube&passive=true"
            + "&continue=https%3A%2F%2Fmusic.youtube.com%2F"
    )

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The page's cookies stay in memory and go with the view, so each
        // attempt starts signed out.
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = proxies
        configuration.websiteDataStore = store
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // See-through until Google's page paints, so the spinner behind shows.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        if let url = Self.startURL {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.openURL = context.environment.openURL
    }

    /// Safari on a Mac: Google's desktop sign-in hands over to YouTube Music directly,
    /// a phone's detours via YouTube's mobile site, and a bare WKWebView may be refused.
    private static var userAgent: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(os.majorVersion).\(os.minorVersion) Safari/605.1.15"
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private static let log = Logger(subsystem: "Lily", category: "sign-in")
        /// A signed-in session has one of these.
        private static let sessionCookies: Set<String> = ["SAPISID", "__Secure-3PAPISID"]

        var parent: SignInWebView
        var openURL: OpenURLAction?
        /// Set once the session is handed over, so later pages don't hand it over again.
        private var signedIn = false

        init(_ parent: SignInWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.shouldPerformDownload { return .cancel }
            // Only the page itself is kept to the chain: frames inside Google's
            // pages load freely, and new-window links go on to `createWebViewWith`.
            guard let frame = action.targetFrame, frame.isMainFrame, let url = action.request.url else { return .allow }
            guard SignInHosts.allows(url) else {
                leave(for: url)
                return .cancel
            }
            // Hand over without loading the YouTube page, which also keeps iOS
            // from opening the YouTube Music app for the link.
            if let host = url.host(), SignInHosts.isYouTube(host), await handOver(from: webView) {
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            // What the page can't show would be a download.
            response.canShowMIMEType ? .allow : .cancel
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for action: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Sign-in's own pages asked for in a new window stay in this one.
            if let url = action.request.url {
                if SignInHosts.allows(url) {
                    webView.load(action.request)
                } else {
                    leave(for: url)
                }
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            guard let url = webView.url, url.scheme == "https", let host = url.host(), SignInHosts.isYouTube(host) else { return }
            Task { await handOver(from: webView) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
            failed(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
            failed(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            parent.onFailure("Couldn't sign in with Google: the sign-in page stopped.")
        }

        /// Hands over YouTube Music's cookies once Google has set a session among
        /// them; false while the page is still signing in.
        @discardableResult
        private func handOver(from webView: WKWebView) async -> Bool {
            guard !signedIn else { return true }
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                .filter(Self.goesToMusic)
            guard !signedIn, cookies.contains(where: { Self.sessionCookies.contains($0.name) }) else { return signedIn }
            signedIn = true
            parent.onSession(cookies)
            return true
        }

        /// Network failures end the attempt. Cancellations don't: a new
        /// navigation or a refused response stops the last one on purpose.
        private func failed(_ error: any Error) {
            guard let error = error as? URLError, error.code != .cancelled else { return }
            parent.onFailure("Couldn't sign in with Google: \(error.localizedDescription)")
        }

        private func leave(for url: URL) {
            Self.log.info("sign-in page: refused \(url.host() ?? "", privacy: .public)\(url.path(), privacy: .private)")
            if SignInHosts.opensInBrowser(url) {
                openURL?(url)
            }
        }

        private static func goesToMusic(_ cookie: HTTPCookie) -> Bool {
            let domain = cookie.domain.trimmingPrefix(".")
            return SignInHosts.musicHost == domain || SignInHosts.musicHost.hasSuffix("." + domain)
        }
    }
}
