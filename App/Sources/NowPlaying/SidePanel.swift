import SwiftUI

enum PanelTab: Int {
    case upNext, lyrics
}

/// The queue and lyrics fade out at the bottom rather than end in a hard cut
/// across the artwork's colour.
struct SidePanel: View {
    let tab: PanelTab
    /// Whether the panel's page is the one on screen.
    let isShown: Bool
    let select: (PanelTab) -> Void
    /// None beside the player, where the panel is always open.
    let close: (() -> Void)?

    static let fade = LinearGradient(
        stops: [.init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Beside the player the controls go to the foot, where a thumb reaches on
    /// an open phone, rather than the top middle, where none does.
    private var isBeside: Bool { close == nil }

    var body: some View {
        VStack(spacing: 0) {
            if !isBeside { tabs }
            content
            if isBeside { tabs }
        }
        .frame(maxHeight: .infinity)
    }

    private var tabs: some View {
        HStack(spacing: 8) {
            // Against the outer edge, under the right thumb.
            if isBeside { Spacer() }
            PillGroup(
                titles: ["Up next", "Lyrics"],
                selection: Binding { tab.rawValue } set: { PanelTab(rawValue: $0).map(select) }
            )
            if let close {
                Spacer()
                IconButton(icon: .close, action: close)
                    .accessibilityLabel("Close panel")
            }
        }
        .frame(minHeight: 48)
        .padding(.leading, NowPlayingScreen.padding)
        .padding(.trailing, isBeside ? NowPlayingScreen.padding : NowPlayingScreen.padding - 8)
    }

    private var content: some View {
        Group {
            switch tab {
            case .upNext:
                UpNextPanel(isShown: isShown, actionsBelow: isBeside) { close?() }
            case .lyrics:
                // Only while on screen, as the player loads lyrics then
                // and they follow the song many times a second.
                if isShown {
                    LyricsPanel { close?() }
                } else {
                    Color.clear
                }
            }
        }
        // Beside the player the queue fades its list alone, clear of its actions.
        .mask {
            if isBeside, tab == .upNext { Color.black } else { Self.fade }
        }
    }
}

/// Whether letting go of a list pulled well past its top closes the panel;
/// the list and the page share the swipe's direction, so it would only bounce.
func pulledPastTop(_ old: ScrollPhase, _ new: ScrollPhase, _ geometry: ScrollGeometry) -> Bool {
    old == .interacting && new != .interacting && geometry.contentOffset.y + geometry.contentInsets.top < -60
}
