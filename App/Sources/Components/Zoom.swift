import SwiftUI
import YTMCore

extension EnvironmentValues {
    /// The tab's namespace that cards name themselves in, for the page they open to zoom out of them.
    @Entry var cardZoom: Namespace.ID?
    /// The app's namespace, for sheets that grow out of the button that opens them.
    @Entry var sheetZoom: Namespace.ID?
}

/// Each tab has its own account button, so Settings grows out of the one on the tab showing.
struct SettingsZoomID: Hashable {
    let tab: AppTab
}

extension Route {
    /// Pages a card opens, which grow out of the card as Apple Music's do; the rest push as usual.
    var zooms: Bool {
        switch self {
        case .album, .playlist, .artist, .genre: true
        default: false
        }
    }
}

extension View {
    /// Names this card as the source its page zooms out of.
    func zoomSource(_ route: Route?) -> some View {
        modifier(ZoomSource(route: route))
    }

    /// Grows the page out of the card that opened it, and shrinks it back into it.
    func zoomsIn(from route: Route, in namespace: Namespace.ID) -> some View {
        modifier(ZoomIn(route: route, namespace: namespace))
    }
}

private struct ZoomSource: ViewModifier {
    let route: Route?

    @Environment(\.cardZoom) private var namespace

    func body(content: Content) -> some View {
        if let route, route.zooms, let namespace {
            content.matchedTransitionSource(id: route, in: namespace)
        } else {
            content
        }
    }
}

private struct ZoomIn: ViewModifier {
    let route: Route
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if route.zooms {
            content.navigationTransition(.zoom(sourceID: route, in: namespace))
        } else {
            content
        }
    }
}
