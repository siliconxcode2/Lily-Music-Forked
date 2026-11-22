import Foundation
import Network
import os

/// The user's own HTTP or SOCKS5 proxy, kept in the Keychain as its address may hold a password.
/// Without one, every session follows the proxy set in iOS.
public enum Proxy {
    /// A proxy address as typed, parsed.
    struct Address: Equatable, Sendable {
        let scheme: String
        /// Without an IPv6 address's brackets.
        let host: String
        let port: UInt16
        let user: String?
        let password: String?

        /// Scheme, host and port, leaving out any user name and password.
        var shown: String {
            "\(scheme)://\(host.contains(":") ? "[\(host)]" : host):\(port)"
        }
    }

    private static let keychainKey = "proxy"
    private static let log = Logger(subsystem: "Lily", category: "proxy")

    /// Read once, by the first session made, as each takes it then: a new one applies from the next start.
    static let inUse: Address? = {
        guard let saved = Keychain.data(for: keychainKey) else { return nil }
        do throws(YTMError) {
            let proxy = try parse(String(decoding: saved, as: UTF8.self))
            log.info("connecting through the proxy at \(proxy.shown)")
            return proxy
        } catch {
            log.warning("ignoring the saved proxy: \(error.message, privacy: .public)")
            return nil
        }
    }()

    /// For every session and the sign-in page; empty without the user's own, so iOS's applies.
    /// The first read touches the Keychain, so never on the main actor.
    public static var configurations: [ProxyConfiguration] {
        inUse.map { [configuration(for: $0)] } ?? []
    }

    /// The proxy saved, without any password, and whether it waits for the next start.
    @concurrent
    public static func saved() async -> (address: String?, pending: Bool) {
        let proxy = Keychain.data(for: keychainKey).flatMap { try? parse(String(decoding: $0, as: UTF8.self)) }
        return (proxy?.shown, proxy != inUse)
    }

    /// Saves `text` as the proxy for the next start, or none when it is empty. Returns its address
    /// without any password, and whether it differs from the one in use, credentials included.
    @concurrent
    public static func save(_ text: String) async throws(YTMError) -> (address: String?, pending: Bool) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let proxy: Address?
        if text.isEmpty {
            guard Keychain.set(nil, for: keychainKey) else { throw YTMError(.refused, "Couldn't clear the saved proxy.") }
            proxy = nil
        } else {
            proxy = try parse(text)
            guard Keychain.set(Data(text.utf8), for: keychainKey) else { throw YTMError(.refused, "Couldn't save the proxy.") }
        }
        return (proxy?.shown, proxy != inUse)
    }

    /// HTTP, HTTPS or SOCKS5, with a host and a port. Without a scheme, HTTP.
    static func parse(_ text: String) throws(YTMError) -> Address {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A sign-in's @, # or / otherwise end the user name or password early.
        let notAnAddress = text.contains("@")
            ? "That isn't a proxy address. Write @, # or / in a user name or password as %40, %23 or %2F."
            : "That isn't a proxy address, like http://127.0.0.1:8080."
        // As on Windows, a sign-in's spaces and stray @ are encoded, and a host outside ASCII becomes punycode.
        guard let parts = URLComponents(string: text.contains("://") ? text : "http://" + text),
              let scheme = parts.scheme?.lowercased() else { throw YTMError(.refused, notAnAddress) }
        var host = parts.encodedHost ?? ""
        // Windows' parser refuses an empty host outright, but for a bare socks5:// or socks5h://.
        if host.isEmpty, parts.port != nil || parts.user != nil || ["http", "https", "ftp", "ws", "wss"].contains(scheme) {
            throw YTMError(.refused, notAnAddress)
        }
        guard ["http", "https", "socks5", "socks5h"].contains(scheme) else {
            throw YTMError(.refused, "Use an http:// or socks5:// address.")
        }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty else { throw YTMError(.refused, "The address needs a host.") }
        // SOCKS has no port to assume.
        guard let port = parts.port ?? ["http": 80, "https": 443][scheme] else {
            throw YTMError(.refused, "The address needs a port, like :1080.")
        }
        // A URI can't hold a percent-encoded host, and only http and https turn one outside ASCII into punycode.
        guard let port = UInt16(exactly: port), !host.contains("%"), scheme.hasPrefix("http") || parts.host == parts.encodedHost else {
            throw YTMError(.refused, notAnAddress)
        }
        return Address(scheme: scheme, host: host.lowercased(), port: port, user: parts.user, password: parts.password)
    }

    /// Every request is HTTPS, so an HTTP proxy is asked to CONNECT. SOCKS5 resolves names
    /// through the proxy either way, so socks5 and socks5h behave alike.
    static func configuration(for proxy: Address) -> ProxyConfiguration {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(proxy.host), port: NWEndpoint.Port(integerLiteral: proxy.port))
        let configuration = proxy.scheme.hasPrefix("socks5")
            ? ProxyConfiguration(socksv5Proxy: endpoint)
            : ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: proxy.scheme == "https" ? NWProtocolTLS.Options() : nil)
        if let user = proxy.user, !user.isEmpty {
            configuration.applyCredential(username: user, password: proxy.password ?? "")
        }
        return configuration
    }
}
