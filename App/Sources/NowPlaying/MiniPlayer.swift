import SwiftUI
import YTMCore

/// From iOS 26.1 the mini player is the tab bar's own accessory, which iOS draws
/// in glass and tucks in beside the tab bar as it shrinks on a scroll. Before
/// that it floats in a glass capsule of its own over each tab (`FloatingMiniPlayer`).
struct MiniPlayerAccessory: ViewModifier {
    let transition: Namespace.ID

    @Environment(AppModel.self) private var app

    static var isAvailable: Bool {
        if #available(iOS 26.1, *) { true } else { false }
    }

    /// What Now Playing zooms out of: the one accessory, or the tab's own capsule.
    static func zoomSource(tab: AppTab) -> AnyHashable {
        isAvailable ? AnyHashable("mini player") : AnyHashable(tab)
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: MiniPlayer.shown(on: app.tab, in: app)) {
                AccessoryMiniPlayer(transition: transition)
            }
        } else {
            content
        }
    }
}

private struct AccessoryMiniPlayer: View {
    let transition: Namespace.ID

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        MiniPlayer(compact: placement == .inline)
            .padding(.horizontal, 6)
            .matchedTransitionSource(id: MiniPlayerAccessory.zoomSource(tab: .home), in: transition)
    }
}

/// Before iOS 26.1: a glass capsule over the tab bar, as tall as it, so its controls are easy to reach.
struct FloatingMiniPlayer: View {
    private static let height: CGFloat = 64
    /// The tab bar's own margins, so the two line up.
    private static let margin: CGFloat = 20
    private static let bottomGap: CGFloat = 8
    /// The height it takes from the page, gap below included.
    static let room = height + bottomGap

    /// Names it as the source Now Playing's zoom grows out of.
    let tab: AppTab
    let transition: Namespace.ID

    @Environment(AppModel.self) private var app

    var body: some View {
        if MiniPlayer.shown(on: tab, in: app) {
            MiniPlayer(compact: false)
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .frame(height: Self.height)
                // Inside the capsule, clear of its rounded ends.
                .overlay(alignment: .bottom) {
                    MiniProgress()
                        .padding(.horizontal, 28)
                        .padding(.bottom, 4)
                }
                .glassEffect(.regular.interactive(), in: Capsule())
                // Shaped as the capsule, so Now Playing shrinks into its rounded
                // ends rather than a rectangle they replace on the last frame.
                .matchedTransitionSource(id: MiniPlayerAccessory.zoomSource(tab: tab), in: transition) {
                    $0.clipShape(.rect(cornerRadius: Self.height / 2))
                }
                .padding(.horizontal, Self.margin)
                .padding(.bottom, Self.bottomGap)
        }
    }
}

/// The song playing, play and next; a tap opens Now Playing. Next is left out
/// when `compact`, as the accessory is beside the shrunken tab bar.
struct MiniPlayer: View {
    let compact: Bool

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        if let track = app.player.current {
            HStack(spacing: 10) {
                ArtworkView(url: track.thumbnail, size: compact ? 28 : 40, radius: 6)
                VStack(alignment: .leading, spacing: 0) {
                    Text(track.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.text)
                    if !compact {
                        Text(track.artistNames)
                            .font(.footnote)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                MiniPlayPause()
                if !compact {
                    IconButton(icon: .next, iconSize: 22, colour: theme.text) { app.player.next() }
                        .accessibilityLabel("Next")
                }
            }
            // As tall as the bar it sits in always, so its text stops growing where the bar's would.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .contentShape(Rectangle())
            .onTapGesture { app.sheet = .nowPlaying }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Open Now Playing") { app.sheet = .nowPlaying }
        }
    }

    static func shown(on tab: AppTab, in app: AppModel) -> Bool {
        app.player.current != nil && !(tab == .search && app.isSearching)
    }
}

/// A bare symbol, as the bar it sits in is already glass.
private struct MiniPlayPause: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let player = app.player
        if player.isBuffering {
            Spinner(size: 24).frame(width: IconButton.minimum, height: IconButton.minimum)
        } else {
            IconButton(icon: player.isPlaying ? .pause : .play, iconSize: 24, colour: theme.text) { player.togglePlayPause() }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
        }
    }
}

/// Pulled only twice a second while playing, as a 2-point line moves too
/// little to need more.
struct MiniProgress: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let player = app.player
        Playhead(interval: 0.5) { time in
            let fraction = player.duration > 0 ? min(max(time / player.duration, 0), 1) : 0
            Capsule()
                .fill(theme.ink.opacity(0.19))
                .overlay {
                    Capsule()
                        .fill(theme.text)
                        .scaleEffect(x: fraction, anchor: .leading)
                }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

/// The playing position, pulled every `interval` while playing and never while paused or `held`.
struct Playhead<Content: View>: View {
    let interval: Double
    var held = false
    @ViewBuilder let content: (Double) -> Content

    @Environment(AppModel.self) private var app
    /// The place last sought, shown while paused as the engine's clock may not
    /// have reached it and a paused playhead is never pulled again.
    @State private var sought: Double?

    var body: some View {
        let player = app.player
        TimelineView(.animation(minimumInterval: interval, paused: !player.isPlaying || held)) { _ in
            content((player.isPlaying ? nil : sought) ?? player.currentTime)
        }
        .onChange(of: player.lastSeek) { _, seek in sought = seek.to }
        .onChange(of: player.isPlaying) { sought = nil }
        .onChange(of: player.current?.id) { sought = nil }
    }
}
