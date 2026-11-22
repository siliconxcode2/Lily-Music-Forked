import SwiftUI
import YTMCore

/// Above the page it carries on solid, so pulling to refresh opens on the
/// colour rather than on the bare panel.
struct PageTint: View {
    /// Further than a pull can open.
    static let overscroll: CGFloat = 1000

    let colour: RGB?
    let top: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        let tint = theme.pageTint(colour)
        LinearGradient(colors: [tint, theme.panel], startPoint: .top, endPoint: .bottom)
            .frame(height: Metrics.tintHeight + top)
            .background(alignment: .top) {
                tint
                    .frame(height: Self.overscroll)
                    .offset(y: -Self.overscroll)
            }
            .padding(.top, -top)
            // On under iPhone Duo's column of tabs, so the page's colour reaches the screen's edge.
            .ignoresSafeArea(edges: .horizontal)
            .animation(Theme.colour, value: colour)
            .accessibilityHidden(true)
    }
}
