import Foundation
import os

extension YTMusic {
    /// Nil when signed out, or when YouTube no longer takes the session. The picture comes
    /// from the guide, as the menu has been seen to keep serving the one before a change.
    @concurrent
    public func account() async throws -> Account? {
        guard await auth.isSignedIn else { return nil }
        async let guide = try? innerTube.post("guide", client: .web)
        let menu = try await innerTube.post("account/account_menu")
        return Account(menu: menu, guidePhoto: Account.photo(await guide?["userProfile", "accountPhoto", "thumbnails"] ?? .missing))
    }

    /// Asks Google for fresh session cookies, as an open YouTube tab does every few minutes:
    /// nothing else renews the app's own session. Does nothing signed out; a failure is only logged.
    @concurrent
    public func renewSignIn() async {
        guard let cookie = await auth.sessionCookie, let url = URL(string: "https://accounts.youtube.com/RotateCookies") else {
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // YouTube calls it from a frame on accounts.youtube.com.
        request.allHTTPHeaderFields = [
            "User-Agent": ClientProfile.browserUserAgent, "Origin": "https://accounts.youtube.com",
            "Content-Type": "application/json", "Cookie": cookie,
        ]
        request.httpBody = Data(#"[000,"-0000000000000000000"]"#.utf8)
        do {
            let (_, response) = try await HTTP.data(for: request)
            await auth.take(response, sent: cookie)
        } catch {
            GoogleAuth.log.warning("Couldn't renew the sign-in: \(sentence(for: error), privacy: .public)")
        }
    }

    /// Checks the stored cookie with YouTube, which costs a page load. Nil when signed out
    /// or YouTube couldn't be asked.
    @concurrent
    public func isSessionValid() async -> Bool? {
        guard let cookie = await auth.sessionCookie, let url = URL(string: "https://www.youtube.com/results?search_query=") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = ["User-Agent": ClientProfile.browserUserAgent, "Cookie": cookie]
        do {
            // Cookies taken in whatever the status, as a browser takes them.
            let (html, _) = try await HTTP.data(for: request, retries: InnerTube.retries, answered: { response in
                await auth.take(response, sent: cookie)
            })
            return Account.isSignedIn(page: String(decoding: html, as: UTF8.self))
        } catch {
            GoogleAuth.log.warning("Couldn't check the sign-in: \(sentence(for: error), privacy: .public)")
            return nil
        }
    }
}

extension Account {
    /// Nil when the menu is a signed-out one.
    init?(menu: JSON, guidePhoto: String?) {
        let header = menu["actions"][0]["openPopupAction", "popup", "multiPageMenuRenderer", "header", "activeAccountHeaderRenderer"]
        guard let name = header["accountName"].text, !name.isEmpty else { return nil }
        self.init(
            name: name,
            handle: header["channelHandle"].text.flatMap { $0.isEmpty ? nil : $0 },
            photo: guidePhoto ?? Self.photo(header["accountPhoto", "thumbnails"])
        )
    }

    /// YouTube's page names the session only for a cookie it takes.
    static func isSignedIn(page html: String) -> Bool {
        html.contains(/"USER_SESSION_ID":"\d+"/)
    }

    /// As a JPEG: an animated picture otherwise comes as a GIF, which artwork isn't decoded from.
    static func photo(_ thumbnails: JSON) -> String? {
        let largest = thumbnails.array.max { ($0["width"].int ?? 0) < ($1["width"].int ?? 0) }
        guard let url = largest?["url"].string else { return nil }
        return url.contains("=") && !url.hasSuffix("-rj") ? url + "-rj" : url
    }
}
