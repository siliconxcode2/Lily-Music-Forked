import Foundation

/// Stateless apart from caches, so one instance is shared.
public final class YTMusic: Sendable {
    public static let shared = YTMusic()

    public let auth: GoogleAuth
    let innerTube: InnerTube
    let store: FileStore

    public init(auth: GoogleAuth = .shared, store: FileStore = .shared) {
        self.auth = auth
        self.store = store
        innerTube = InnerTube(auth: auth, store: store)
    }
}
