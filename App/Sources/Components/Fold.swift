import SwiftUI

enum Fold {
    /// iPhone Duo's inner display while wider than tall, where a screen's two
    /// halves sit either side of the fold. Not when it is turned upright: the
    /// halves would stack, leaving each too short.
    static func isSplit(_ sizeClass: UserInterfaceSizeClass?, isWide: Bool) -> Bool {
        guard #available(iOS 27.1, *) else { return false }
        return sizeClass == .regular && isWide
    }

    /// iPhone Duo half open and stood like a laptop: taller than wide, its
    /// fold running across, with the top half upright and the bottom flat.
    nonisolated static func isStood(_ proxy: GeometryProxy) -> Bool {
        guard #available(iOS 27.1, *), proxy.size.height > proxy.size.width else { return false }
        return proxy.reservedRegions(kind: .division).contains { $0.isActive && $0.frame.width > $0.frame.height }
    }
}
