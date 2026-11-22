import SwiftUI
import YTMCore

extension EnvironmentValues {
    /// Library's pages, whose playlists can be pinned to the top of its playlists.
    @Entry var pinsPlaylists = false
}

struct CardView: View {
    let card: Card
    let width: CGFloat

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.pinsPlaylists) private var pinsPlaylists

    /// Carousel and grid cards share one decode, so art already seen in a carousel draws at once.
    static func artPixels(scale: CGFloat) -> Int {
        ArtworkImage.pixels(edge: Metrics.cardWidth, scale: scale)
    }

    var body: some View {
        Button { app.activate(card, displayScale: displayScale) } label: {
            VStack(alignment: .leading, spacing: 4) {
                ArtworkView(
                    url: card.thumbnail, size: width, round: card.kind == .artist, radius: Metrics.cardArtRadius,
                    pixelEdge: Self.artPixels(scale: displayScale), shadow: (theme.shadowSoft, 8, 6)
                )
                    .padding(.bottom, 4)
                Text(card.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.text)
                HStack(spacing: 4) {
                    // Read only where pins show, so other cards never redraw for them.
                    if pinsPlaylists, app.pinned.contains(card.id) {
                        IconView(icon: .pin, size: 14, colour: theme.accent)
                            .accessibilityLabel("Pinned")
                    }
                    Text(card.subtitle)
                        .font(.footnote)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.97))
        .zoomSource(card.route)
        // A long press lifts a larger look at it above the menu, as Apple Music's does.
        .contextMenu {
            CardMenu(card: card)
        } preview: {
            CardPreview(card: card)
                // A preview is drawn apart from the page, so it is handed the theme itself.
                .environment(\.theme, theme)
        }
    }
}

/// The card's artwork large, with its title under it.
private struct CardPreview: View {
    private static let edge: CGFloat = 260

    let card: Card

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ArtworkView(url: card.thumbnail, size: Self.edge, round: card.kind == .artist, radius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.headline)
                    .foregroundStyle(theme.text)
                if !card.subtitle.isEmpty {
                    Text(card.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .lineLimit(2)
        }
        .frame(width: Self.edge)
        .padding(16)
        .background(theme.elevated)
    }
}

struct CarouselRow: View {
    let cards: [Card]

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: Metrics.cardGap) {
                ForEach(cards.indices, id: \.self) { index in
                    CardView(card: cards[index], width: Metrics.cardWidth)
                        // Cards ease out a touch as they leave the row's edges.
                        .scrollTransition(.interactive, axis: .horizontal) { card, phase in
                            card
                                .scaleEffect(phase.isIdentity ? 1 : 0.96)
                                .opacity(phase.isIdentity ? 1 : 0.8)
                        }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, Metrics.pagePadding, for: .scrollContent)
        .scrollClipDisabled()
    }
}

struct CardGrid: View {
    let cards: [Card]
    let width: CGFloat

    var body: some View {
        let (count, cell) = Metrics.cardColumns(width: width)
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(cell), spacing: Metrics.cardGap, alignment: .top), count: count),
            alignment: .leading,
            spacing: Metrics.cardGap * 2
        ) {
            ForEach(cards.indices, id: \.self) { index in
                CardView(card: cards[index], width: cell)
            }
        }
        .padding(.horizontal, Metrics.pagePadding)
    }
}
