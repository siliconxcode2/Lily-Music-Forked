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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text)
                HStack(spacing: 4) {
                    // Read only where pins show, so other cards never redraw for them.
                    if pinsPlaylists, app.pinned.contains(card.id) {
                        IconView(icon: .pin, size: 14, colour: theme.accent)
                            .accessibilityLabel("Pinned")
                    }
                    Text(card.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.97))
        .contextMenu { CardMenu(card: card) }
    }
}

struct CarouselRow: View {
    let cards: [Card]

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: Metrics.cardGap) {
                ForEach(cards.indices, id: \.self) { index in
                    CardView(card: cards[index], width: Metrics.cardWidth)
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
