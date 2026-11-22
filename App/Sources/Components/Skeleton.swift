import SwiftUI
import YTMCore

/// A wash in the shape of something still loading.
struct Bone: View {
    var width: CGFloat?
    var height: CGFloat?
    var radius: CGFloat = 4

    var body: some View {
        // iOS's own fill for placeholders, so the bones match the system's in every look.
        RoundedRectangle(cornerRadius: radius)
            .fill(.quaternary)
            .frame(width: width, height: height)
    }

    /// Ragged, so lines read as text.
    private static let lengths: [CGFloat] = [170, 120, 150, 100, 140, 180, 130]

    static func length(_ index: Int) -> CGFloat {
        lengths[index % lengths.count]
    }
}

extension View {
    /// Shown after 250 ms, so a quick load never flashes it, then pulsing.
    func skeleton() -> some View {
        modifier(SkeletonPulse())
    }
}

private struct SkeletonPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var due = false

    func body(content: Content) -> some View {
        content
            .phaseAnimator(reduceMotion ? [1] : [1, 0.5]) { bones, opacity in
                bones.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.8)
            }
            .opacity(due ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                withAnimation(Theme.normal) { due = true }
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading")
    }
}

/// Shaped as the route's page builder lays it out, so the page lands in place.
struct PageSkeleton: View {
    let route: Route

    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var isWide = false

    var body: some View {
        ZStack {
            if #available(iOS 27.1, *), isSplit {
                // `PageContent`'s halves: the header at the foot of its own, the tracks beside it.
                ArrangementView {
                    VStack(alignment: .leading, spacing: 0) {
                        HeaderBones(art: true)
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                } secondary: {
                    VStack(alignment: .leading, spacing: 0) {
                        tracks
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
                }
                .arrangementViewStyle(.split)
                .skeleton()
            } else {
                column
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isWide = $0 }
    }

    /// Albums' and playlists', whose header has art, the real page puts beside its tracks.
    private var isSplit: Bool {
        switch route {
        case .album, .playlist: Fold.isSplit(sizeClass, isWide: isWide)
        default: false
        }
    }

    @ViewBuilder private var tracks: some View {
        // Its space only.
        TrackColumns()
            .hidden()
            .padding(.horizontal, Metrics.pagePadding)
        TrackBones(count: 10, art: !isAlbum)
    }

    private var column: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch route {
                case .album, .playlist, .history, .librarySongs:
                    HeaderBones(art: true)
                    tracks
                case .artist:
                    BannerBones()
                    SectionBones(layouts: [nil])
                case .libraryPlaylists, .libraryAlbums, .libraryArtists:
                    HeaderBones(art: false)
                    GridBones()
                case .browse, .newReleases:
                    // Grids: a discography, most often, or new releases.
                    HeaderBones(art: false, label: false)
                    GridBones()
                case .library, .downloads:
                    SectionBones(layouts: [.grid])
                case .explore:
                    SectionBones(layouts: [.chips, .chips])
                case .moodsAndGenres:
                    HeaderBones(art: false, label: false)
                    SectionBones(layouts: [.chips])
                case .search:
                    SectionBones(layouts: [nil])
                case .genre:
                    HeaderBones(art: false)
                    SectionBones(layouts: [.carousel, .carousel])
                case .charts:
                    HeaderBones(art: false, label: false)
                    SectionBones(layouts: [.carousel, .carousel])
                case .home:
                    Bone(width: 220, height: 28)
                        .padding(.horizontal, Metrics.pagePadding)
                        .frame(height: Metrics.greetingHeight, alignment: .bottom)
                    if app.isSignedIn {
                        SectionBones(layouts: YTMusic.homeShelves.map(\.layout))
                    } else {
                        // The charts, as `publicHome` orders them: Trending, New releases, Top artists, genres.
                        SectionBones(layouts: [nil, .carousel])
                        SectionTitleBone()
                        CarouselBones(round: true)
                        SectionBones(layouts: [.chips])
                    }
                }
            }
        }
        .scrollDisabled(true)
        .skeleton()
    }

    private var isAlbum: Bool {
        if case .album = route { true } else { false }
    }
}

/// Only a header with art has songs, so details and actions.
private struct HeaderBones: View {
    let art: Bool
    var label = true

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if art {
                Bone(width: Metrics.headerArt, height: Metrics.headerArt, radius: Metrics.cardArtRadius)
                    .frame(maxWidth: .infinity)
            }
            HeaderTextBones(label: label, details: art)
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.top, 16)
        .padding(.bottom, 24)
        if art {
            ActionBones()
        }
    }
}

/// Stops at the bar; the real banner reaches under it.
private struct BannerBones: View {
    var body: some View {
        Bone(height: Metrics.bannerHeight, radius: 0)
            .overlay(alignment: .bottomLeading) {
                HeaderTextBones(label: true, details: true)
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.bottom, 24)
            }
        ActionBones()
    }
}

/// `HeaderText`'s lines, at their heights; it leaves out an empty label or details.
private struct HeaderTextBones: View {
    let label: Bool
    let details: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if label {
                Bone(width: 70, height: 12)
                    .frame(height: 17)
            }
            Bone(width: 220, height: 40)
                .frame(height: 52)
            if details {
                Bone(width: 160, height: 12)
                    .frame(height: 17)
            }
        }
    }
}

private struct ActionBones: View {
    var body: some View {
        HStack(spacing: 20) {
            Bone(width: 56, height: 56, radius: 28)
            Bone(width: 48, height: 48, radius: 24)
        }
        .padding(.horizontal, Metrics.pagePadding)
        .frame(height: Metrics.actionsHeight)
    }
}
