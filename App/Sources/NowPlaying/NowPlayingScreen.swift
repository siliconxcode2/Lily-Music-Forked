import SwiftUI
import YTMCore

/// The two pages scroll natively, so a swipe follows the finger and can't be
/// lost to the zoom's own close. A regular width, iPhone Duo's inner display,
/// has room for both at once, as the desktop's player and panel are; stood
/// half open, the artwork or lyrics face the room from the upright half and
/// every control sits on the flat one.
struct NowPlayingScreen: View {
    static let padding: CGFloat = 24

    private enum Page: Hashable {
        case artwork, panel
    }

    private enum Layout {
        case pager, sideBySide, stand
    }

    private nonisolated struct Shape: Equatable {
        var isWide = false
        var isStood = false
    }

    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var page: Page? = .artwork
    @State private var tab = PanelTab.upNext
    @State private var shape = Shape()
    /// On the phone held upright, lyrics take the artwork's place above the controls, as Apple Music's do.
    @State private var inlineLyrics = false

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            if let track = app.player.current {
                if #available(iOS 27.1, *), layout == .stand {
                    stand(track)
                } else {
                    NowPlayingTopBar(track: track)
                    if #available(iOS 27.1, *), layout == .sideBySide {
                        sideBySide(track)
                    } else {
                        pager(track)
                    }
                }
            }
        }
        .padding(.bottom, 8)
        .onGeometryChange(for: Shape.self) { proxy in
            Shape(isWide: proxy.size.width > proxy.size.height, isStood: Fold.isStood(proxy))
        } action: { shape = $0 }
        // Each layout starts at the artwork; stood, a tab left on lyrics would open them.
        .onChange(of: layout) {
            page = .artwork
            inlineLyrics = false
            if $1 == .stand { tab = .upNext }
        }
        .background { NowPlayingBackground() }
        // On the panel, or stood lyrics, a pull down goes back to the artwork
        // rather than closing the screen.
        .interactiveDismissDisabled((page == .panel && layout != .sideBySide) || (layout == .stand && lyricsShown) || inlineLyrics)
        .sheet(item: $app.nowPlayingPicker) { PlaylistPickerSheet(track: $0) }
        .onAppear { app.nowPlayingShown = true }
        .onDisappear {
            app.nowPlayingShown = false
            app.player.showsLyrics = false
        }
        // Set here rather than as the lyrics appear, as opening or closing the
        // phone swaps one lyrics view for another in no set order.
        .onChange(of: lyricsShown, initial: true) { app.player.showsLyrics = $1 }
        .modifier(FoldToScrub(isSideBySide: layout == .sideBySide))
    }

    private var layout: Layout {
        if Fold.isSplit(sizeClass, isWide: shape.isWide) { return .sideBySide }
        return sizeClass == .regular && shape.isStood ? .stand : .pager
    }

    private var lyricsShown: Bool {
        inlineLyrics || tab == .lyrics && (layout != .pager || page == .panel)
    }

    private func pager(_ track: Track) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                // Each page hidden from VoiceOver while off screen,
                // so it reads one set of controls.
                artworkPage(track, open: pagerOpen)
                    .containerRelativeFrame(.vertical)
                    .accessibilityHidden(page != .artwork)
                    .id(Page.artwork)
                panelPage(track, select: show)
                    .containerRelativeFrame(.vertical)
                    .accessibilityHidden(page != .panel)
                    .id(Page.panel)
            }
            .scrollTargetLayout()
            .background(PagerBounceOff())
        }
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        // The page counts as shown once past halfway, so a swipe
        // down from the panel stays one page until it settles.
        .scrollPosition(id: $page, anchor: .center)
        .scrollIndicators(.hidden)
    }

    /// Either side of the fold, where there is one.
    @available(iOS 27.1, *)
    private func sideBySide(_ track: Track) -> some View {
        ArrangementView {
            artworkPage(track, open: select)
        } secondary: {
            SidePanel(tab: tab, isShown: true, select: select, close: nil)
        }
        .arrangementViewStyle(.split)
    }

    /// Stood, the upright half is out of reach, so every control is on the flat one.
    @available(iOS 27.1, *)
    private func stand(_ track: Track) -> some View {
        ArrangementView {
            if lyricsShown {
                LyricsPanel { standSelect(.lyrics) }
            } else {
                LargeArtwork(url: track.thumbnail)
                    .padding(Self.padding)
            }
        } secondary: {
            // On the queue alone, even for the frame before a change of layout resets the tab.
            if page == .panel, tab == .upNext {
                panelPage(track, select: standSelect)
            } else {
                VStack(spacing: 0) {
                    NowPlayingTopBar(track: track)
                    Spacer(minLength: 0)
                    controls(track, open: standSelect)
                }
            }
        }
        .arrangementViewStyle(.split)
    }

    /// Lyrics swap in for the artwork above, and back again; the queue opens below.
    private func standSelect(_ next: PanelTab) {
        withAnimation(Theme.normal) {
            if next == .lyrics {
                tab = lyricsShown ? .upNext : .lyrics
                page = .artwork
            } else {
                tab = .upNext
                page = .panel
            }
        }
    }

    private func artworkPage(_ track: Track, open: @escaping (PanelTab) -> Void) -> some View {
        VStack(spacing: 0) {
            ZStack {
                if inlineLyrics {
                    LyricsPanel { pagerOpen(.lyrics) }
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    LargeArtwork(url: track.thumbnail)
                        .modifier(SwipeToSkip())
                        .accessibilityAction(named: "Up Next") { open(.upNext) }
                        .padding(.vertical, 12)
                        .padding(.horizontal, Self.padding)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(maxHeight: .infinity)
            controls(track, open: open)
        }
    }

    /// Lyrics swap in for the artwork and back; the queue is the page below.
    private func pagerOpen(_ next: PanelTab) {
        if next == .lyrics {
            withAnimation(Theme.normal) { inlineLyrics.toggle() }
        } else {
            show(next)
        }
    }

    private func controls(_ track: Track, open: @escaping (PanelTab) -> Void) -> some View {
        VStack(spacing: 0) {
            TrackTitle(track: track, compact: false)
            Scrubber()
                .padding(.top, 12)
            TransportControls()
            PlayerOptions(open: open)
        }
        .padding(.horizontal, Self.padding)
    }

    private func panelPage(_ track: Track, select: @escaping (PanelTab) -> Void) -> some View {
        VStack(spacing: 0) {
            CompactControls(track: track)
            SidePanel(tab: tab, isShown: page == .panel, select: select) {
                withAnimation(Theme.normal) { page = .artwork }
            }
        }
    }

    private func select(_ next: PanelTab) {
        withAnimation(Theme.normal) { tab = next }
    }

    private func show(_ next: PanelTab) {
        withAnimation(Theme.normal) {
            tab = next
            page = .panel
        }
    }
}

/// Stops the pager bouncing, so a swipe down at the artwork goes straight to
/// the zoom's close; `scrollBounceBehavior` can't while content overflows. Its
/// nearest scroll view is the pager, never the queue, which needs its bounce.
// shortcut: relies on SwiftUI's ScrollView being a UIScrollView; drop it once SwiftUI can turn the bounce off.
private struct PagerBounceOff: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        // Behind both pages, so it must never take a touch meant for them.
        probe.isUserInteractionEnabled = false
        return probe
    }

    // The work is done in `didMoveToWindow`, once the probe is in the pager.
    func updateUIView(_ probe: Probe, context: Context) {}

    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var view = superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            (view as? UIScrollView)?.bounces = false
        }
    }
}

private struct CompactControls: View {
    let track: Track

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ArtworkView(url: track.thumbnail, size: 52)
                TrackTitle(track: track, compact: true)
                PlayPauseButton(size: 44)
                IconButton(icon: .next, size: 44, iconSize: 26, colour: theme.text) { app.player.next() }
                    .accessibilityLabel("Next")
            }
            MiniProgress()
        }
        .padding(.horizontal, NowPlayingScreen.padding)
        .padding(.vertical, 8)
    }
}

/// The menu leaves out rating, which is beside the title, and queueing, which
/// has no use for the song playing.
private struct NowPlayingTopBar: View {
    let track: Track

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            IconButton(icon: .close, size: 44, iconSize: 20, colour: theme.text, glass: true) { dismiss() }
                .accessibilityLabel("Close")
            Spacer()
            SleepTimerBadge()
            Menu {
                if app.isSignedIn {
                    Button("Save to Playlist", systemImage: "text.badge.plus") { app.addToPlaylist(track) }
                }
                SleepTimerMenu()
                TrackDownloadItem(track: track)
                TrackLinks(track: track)
            } label: {
                IconView(icon: .more, size: 22, colour: theme.text)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, NowPlayingScreen.padding - 8)
        .padding(.top, 12)
    }
}

/// Decoded at the player's shared size, which is fetched ahead with the song.
/// It steps back while paused and springs forward on play, as Apple Music's does.
private struct LargeArtwork: View {
    let url: String?

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { space in
            let edge = min(space.size.width, space.size.height)
            ArtworkView(url: url, size: edge, radius: 8, pixelEdge: ImagePipeline.playerEdge, shadow: (theme.shadowSoft, 16, 8))
                .scaleEffect(app.player.isPlaying ? 1 : 0.82)
                .animation(Theme.bouncy, value: app.player.isPlaying)
                .frame(width: space.size.width, height: space.size.height)
        }
    }
}

/// The artwork's colours where they sit in it, as a blurred copy would show
/// them without the cost of blurring. While playing, the colours drift slowly,
/// as Apple Music's do; still with Reduce Motion, or paused.
private struct NowPlayingBackground: View {
    private static let edge = ArtworkPalette.meshEdge
    private static let points = (0..<edge * edge).map { cell in
        SIMD2(Float(cell % edge), Float(cell / edge)) / Float(edge - 1)
    }
    /// How far an inner point wanders, as a share of the screen.
    private static let drift: Float = 0.08

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let mesh = app.artwork?.mesh {
                // Each row darker than the one above, the bottom by a third.
                let colours = mesh.enumerated().map { cell, colour in
                    theme.tint(colour.darker(Double(cell / Self.edge) / Double(2 * (Self.edge - 1))))
                }
                // A slow wander needs no more than 30 frames a second.
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !app.player.isPlaying)) { timeline in
                    MeshGradient(
                        width: Self.edge, height: Self.edge,
                        points: Self.drifted(at: timeline.date.timeIntervalSinceReferenceDate),
                        colors: colours
                    )
                }
            } else {
                theme.panel
            }
        }
        .animation(Theme.colour, value: app.artwork)
        .ignoresSafeArea()
    }

    /// The edge points stay on the edges, so the mesh always fills the screen; the inner ones circle slowly.
    private static func drifted(at time: TimeInterval) -> [SIMD2<Float>] {
        points.enumerated().map { cell, point in
            let column = cell % edge
            let row = cell / edge
            guard column > 0, column < edge - 1, row > 0, row < edge - 1 else { return point }
            let t = Float(time.truncatingRemainder(dividingBy: 3_600))
            let phase = Float(cell) * 1.7
            return point + SIMD2(sin(t * 0.21 + phase), cos(t * 0.17 + phase)) * drift
        }
    }
}

/// Apple Music's lengths, the end of the song, and Turn Off while one runs.
private struct SleepTimerMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu("Sleep Timer", systemImage: "moon.zzz") {
            if app.sleepTimer != nil {
                Button("Turn Off", systemImage: "xmark") { app.setSleepTimer(nil) }
            }
            Button("End of Song") { app.setSleepTimer(.endOfSong) }
            ForEach(AppModel.sleepLengths, id: \.self) { minutes in
                Button(minutes == 60 ? "1 Hour" : "\(minutes) Minutes") {
                    app.setSleepTimer(.at(.now + Double(minutes * 60)))
                }
            }
        }
    }
}

/// The time left, counting down, beside the menu while a sleep timer runs.
private struct SleepTimerBadge: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        if let timer = app.sleepTimer {
            HStack(spacing: 4) {
                IconView(icon: .sleep, size: 14, colour: theme.text)
                switch timer {
                case .at(let end):
                    Text(timerInterval: Date.now...max(end, .now), countsDown: true)
                        .monospacedDigit()
                case .endOfSong:
                    Text("End of Song")
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(theme.text)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .glassEffect(.regular, in: Capsule())
            .transition(.scale.combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sleep timer")
        }
    }
}
