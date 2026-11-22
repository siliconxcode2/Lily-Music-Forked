import SwiftUI
import YTMCore
import YTMPlayback

struct PageContent: View {
    let page: Page
    let route: Route
    /// Nil for a page held on the device, as the songs played are.
    var model: PageModel?

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var frame = Frame()
    @State private var position = ScrollPosition(edge: .top)
    @State private var titleShown = false
    @State private var artworkTint: RGB?
    @State private var isWide = false
    @State private var dialog: PlaylistDialog?
    @State private var newName = ""

    /// So a page opened again starts in its colour. Keyed by URL alone: the
    /// size isn't known until the header is measured, and doesn't change it.
    private static var tints: [String: RGB] = [:]

    /// The scroll view's width, the bar's height over it, and the column
    /// iPhone Duo keeps its tabs in down one side.
    private nonisolated struct Frame: Equatable {
        var width: CGFloat = 0
        var top: CGFloat = 0
        var side: CGFloat = 0
    }

    private nonisolated struct TintSource: Hashable {
        let url: String
        let pixels: Int
    }

    var body: some View {
        // Not a Group, so a change of layout doesn't restart the tasks below.
        ZStack {
            if #available(iOS 27.1, *), let header = splitHeader {
                ArrangementView {
                    // At the foot of its half, under the thumb, unless it is too tall to fit.
                    ViewThatFits(in: .vertical) {
                        headerView(header).frame(maxHeight: .infinity, alignment: .bottom)
                        ScrollView { headerView(header) }
                    }
                } secondary: {
                    scroller
                }
                .arrangementViewStyle(.split)
                .background(alignment: .top) { tint.modifier(PastEdges()) }
            } else {
                scroller
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isWide = $0 }
        // The scroll view is a new one, at the top, either side of the change.
        .onChange(of: splitHeader == nil) { titleShown = false }
        .background { theme.panel.modifier(PastEdges()).ignoresSafeArea() }
        .navigationTitle(page.header?.title ?? "")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if let header = page.header {
                ToolbarItem(placement: .principal) {
                    StickyTitle(title: header.title, canPlay: canPlay) { app.perform(.play, on: page) }
                        .opacity(stickyTitleShown ? 1 : 0)
                        .animation(Theme.normal, value: stickyTitleShown)
                }
            }
        }
        .modifier(Refresh(model: model))
        .task(id: tintSource) {
            guard let tintSource else { return }
            // Held in the view too, as another page may empty the cache while this one stays in a stack.
            if let cached = Self.tints[tintSource.url] {
                artworkTint = cached
                return
            }
            if let background = await ArtworkColours.background(url: tintSource.url, pixelEdge: tintSource.pixels) {
                artworkTint = background
                // Emptied once full rather than evicted one by one: past 64 pages, a revisit only fades in again.
                if Self.tints.count >= 64 { Self.tints.removeAll() }
                Self.tints[tintSource.url] = background
            }
        }
        // The cards' art is fetched as the page is built, rather than as each
        // scrolls in, and stops once it is left.
        .task(id: [cardCount, model?.replacements ?? 0]) { await prefetchArt() }
        .environment(\.pinsPlaylists, route.showsPins)
        .modifier(PlaylistDialogs(dialog: $dialog, name: $newName, title: page.header?.title ?? "", model: model))
    }

    /// An album's or playlist's header, beside its tracks rather than over them.
    private var splitHeader: PageHeader? {
        guard Fold.isSplit(sizeClass, isWide: isWide), let header = page.header, !header.banner, header.thumbnail != nil else { return nil }
        return header
    }

    /// Beside the tracks the header never scrolls away, so neither is it repeated in the bar.
    private var stickyTitleShown: Bool {
        titleShown && splitHeader == nil
    }

    private var tint: PageTint {
        PageTint(colour: artworkTint ?? tintSource.flatMap { Self.tints[$0.url] } ?? Theme.routeTint(route), top: frame.top)
    }

    private func headerView(_ header: PageHeader) -> PageHeaderView {
        PageHeaderView(
            header: header,
            canPlay: canPlay,
            canShuffle: canPlay || header.shufflePlaylistId != nil,
            canRadio: header.radioId != nil,
            topInset: frame.top,
            extendsBanner: frame.side > 0,
            download: canPlay && Downloads.isDownloadable(route) ? DownloadButton(route: route, page: page) : nil,
            link: route.link,
            model: model,
            edit: app.ownPlaylist(model) == nil ? nil : { which in
                newName = header.title
                dialog = which
            }
        ) { app.perform($0, on: page) }
    }

    private var scroller: some View {
        let isSplit = splitHeader != nil
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if route == .home {
                    Greeting()
                }
                if !isSplit, let header = page.header {
                    headerView(header)
                }
                let ownPlaylist = app.ownPlaylist(model) == nil ? nil : model
                ForEach(page.sections.indices, id: \.self) { index in
                    SectionRows(section: page.sections[index], width: frame.width - 2 * Metrics.pagePadding)
                        // Its own songs are the first section's; any after are YouTube's suggestions.
                        .environment(\.ownPlaylist, index == 0 ? ownPlaylist : nil)
                }
                // The rest loads while the page is on screen (`PageScreen`).
                if let more = page.more {
                    VStack(alignment: .leading, spacing: 0) {
                        if case .shelves = more {
                            SectionBones(layouts: model?.shelvesToCome ?? [])
                        } else {
                            TrackBones(count: 3, art: true)
                        }
                    }
                    .skeleton()
                }
            }
            .padding(.bottom, Metrics.pageBottom)
            .background(alignment: .top) {
                if !isSplit {
                    tint.modifier(PastEdges())
                }
            }
        }
        // The mask stands in for the scroll view's clip so it can run past
        // the sides (`PastEdges`). It overhangs top and bottom as the safe
        // area eases in on a tab's first page, briefly clipping the tint; not
        // while Now Playing shrinks the screen, whose edges still clip.
        .scrollClipDisabled()
        .mask { PastEdgesMask() }
        .scrollPosition($position)
        .onChange(of: model?.replacements) { position.scrollTo(edge: .top) }
        // The tint runs unbroken under the bar, whose edge shows only with
        // the sticky title.
        .scrollEdgeEffectHidden(!stickyTitleShown, for: .top)
        // Beside the header, the tracks' half alone.
        .onGeometryChange(for: Frame.self) { proxy in
            Frame(
                width: proxy.size.width, top: proxy.safeAreaInsets.top,
                side: max(proxy.safeAreaInsets.leading, proxy.safeAreaInsets.trailing)
            )
        } action: { frame = $0 }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > Metrics.stickyTitleAfter
        } action: { _, shown in
            titleShown = shown
        }
    }

    private var canPlay: Bool {
        !page.headerTracks.isEmpty
    }

    /// So a further step that adds cards fetches their art too, and one that
    /// only adds songs fetches nothing.
    private var cardCount: Int {
        page.sections.reduce(0) { count, section in
            if case .cards(let s) = section { count + s.cards.count } else { count }
        }
    }

    /// Song rows load their own art as they come on screen, so a long
    /// playlist's isn't all downloaded at once. The chips and the top result
    /// draw none of this art, or their own, so they are left out.
    private func prefetchArt() async {
        // The first screen's own loads go first, so none is asked for twice.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        var cards: [String] = []
        for case .cards(let s) in page.sections where [.carousel, .grid, .speedDial].contains(s.layout) {
            cards += s.cards.compactMap(\.thumbnail)
        }
        await ImagePipeline.shared.prefetch(cards, pixelEdge: CardView.artPixels(scale: displayScale))
    }

    private var tintSource: TintSource? {
        guard let header = page.header, let url = header.thumbnail else { return nil }
        let edge = PageHeaderView.artEdge(header, topInset: frame.top)
        return TintSource(url: url, pixels: ArtworkImage.pixels(edge: edge, scale: displayScale))
    }
}

private struct Greeting: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Text(Self.greeting(hour: Calendar.current.component(.hour, from: .now)))
            .font(.system(size: 32, weight: .heavy))
            .foregroundStyle(theme.text)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, Metrics.pagePadding)
            .frame(height: Metrics.greetingHeight, alignment: .bottom)
    }

    private static func greeting(hour: Int) -> String {
        switch hour {
        case 4..<12: "Good morning"
        case 12..<18: "Good afternoon"
        case 18..<23: "Good evening"
        default: "Good night"
        }
    }
}

/// While Now Playing's zoom shrinks the screen, the page runs past its sides
/// to hide the black behind; only then, or a sliding page would overlap the
/// one beside it.
private struct PastEdges: ViewModifier {
    static let width: CGFloat = 16

    @Environment(AppModel.self) private var app

    static func shown(in app: AppModel) -> Bool {
        app.sheet == .nowPlaying || app.nowPlayingShown
    }

    func body(content: Content) -> some View {
        content.padding(.horizontal, Self.shown(in: app) ? -Self.width : 0)
    }
}

/// A view of its own so Now Playing opening or closing redraws only the clip.
private struct PastEdgesMask: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Rectangle()
            .padding(.vertical, PastEdges.shown(in: app) ? 0 : -PageTint.overscroll)
            .modifier(PastEdges())
            .ignoresSafeArea()
    }
}

private struct StickyTitle: View {
    let title: String
    let canPlay: Bool
    let play: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            if canPlay {
                PlayButton(size: 30, action: play)
            }
            Text(title)
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(theme.text)
                .lineLimit(1)
        }
    }
}

private struct Refresh: ViewModifier {
    let model: PageModel?

    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        if let model {
            content.refreshable { await model.refresh(in: app) }
        } else {
            content
        }
    }
}
