import SwiftUI
import YTMCore

struct SpeedDial: View {
    let cards: [Card]
    /// The page's width inside its padding.
    let width: CGFloat

    @State private var page: Int? = 0

    private static let columns = 3
    private static let perPage = 9
    /// Past a phone's width, as on iPhone Duo's inner display, a page this
    /// wide is as tall as the screen, so the next one shows beside it instead.
    static let maxPageWidth: CGFloat = 420

    /// The die ends the first page, as YouTube's does.
    private enum Tile {
        case card(Card)
        case die
    }

    var body: some View {
        let pageWidth = min(width, Self.maxPageWidth)
        let cell = (pageWidth - CGFloat(Self.columns - 1) * Metrics.cardGap) / CGFloat(Self.columns)
        let pages = Self.pages(of: cards)
        // Every page as tall as a full one, so the dots stay put; a lone page as tall as its rows.
        let rows = pages.count > 1 ? 3 : Self.rows(pages.first?.count ?? 0)
        VStack(spacing: 16) {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 2 * Metrics.pagePadding) {
                    ForEach(pages.indices, id: \.self) { index in
                        Grid(horizontalSpacing: Metrics.cardGap, verticalSpacing: Metrics.cardGap) {
                            ForEach(0..<Self.rows(pages[index].count), id: \.self) { row in
                                GridRow {
                                    ForEach(pages[index].indices.dropFirst(row * Self.columns).prefix(Self.columns), id: \.self) { slot in
                                        tile(pages[index][slot], size: cell)
                                    }
                                }
                            }
                        }
                        .frame(width: pageWidth, height: CGFloat(rows) * cell + CGFloat(max(rows - 1, 0)) * Metrics.cardGap, alignment: .topLeading)
                        .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
            .scrollPosition(id: $page)
            .scrollIndicators(.hidden)
            .contentMargins(.leading, Metrics.pagePadding, for: .scrollContent)
            // Room after the last page for it to scroll to the front, so its dot can light.
            .contentMargins(.trailing, Metrics.pagePadding + width - pageWidth, for: .scrollContent)
            .scrollClipDisabled()
            if pages.count > 1 {
                PageDots(count: pages.count, current: min(page ?? 0, pages.count - 1))
            }
        }
        .padding(.bottom, 8)
        // A fresh feed starts from its first page, as the page itself starts from the top.
        .onChange(of: cards) { page = 0 }
    }

    @ViewBuilder
    private func tile(_ tile: Tile, size: CGFloat) -> some View {
        switch tile {
        case .card(let card): SpeedDialTile(card: card, size: size)
        case .die: SpeedDialDie(cards: cards, size: size)
        }
    }

    private static func pages(of cards: [Card]) -> [[Tile]] {
        var tiles = cards.map(Tile.card)
        if !tiles.isEmpty { tiles.insert(.die, at: min(perPage - 1, tiles.count)) }
        return stride(from: 0, to: tiles.count, by: perPage).map { Array(tiles[$0..<min($0 + perPage, tiles.count)]) }
    }

    private static func rows(_ count: Int) -> Int {
        (count + columns - 1) / columns
    }
}

private struct SpeedDialTile: View {
    let card: Card
    let size: CGFloat

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    static let radius: CGFloat = 10

    var body: some View {
        Button { app.activate(card, displayScale: displayScale) } label: {
            ZStack(alignment: .bottom) {
                ArtworkView(
                    url: card.thumbnail, size: size, round: card.kind == .artist, radius: 0,
                    pixelEdge: CardView.artPixels(scale: displayScale)
                )
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: UnitPoint(x: 0.5, y: 0.5), endPoint: .bottom)
                HStack(spacing: 2) {
                    Text(card.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(theme.onColour)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if card.route != nil {
                        IconView(icon: .chevron, size: 20, colour: theme.onColour)
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .padding(.bottom, 8)
            }
            .frame(width: size, height: size)
            // Dark behind an artist's round art, so the shade at the foot darkens its corners evenly.
            .background(card.kind == .artist ? Color.black : theme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: Self.radius))
            .overlay {
                if let track = card.track, app.isPlaying(track) {
                    RoundedRectangle(cornerRadius: Self.radius + 4)
                        .strokeBorder(theme.text, lineWidth: 3)
                        .padding(-5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.97))
        .zoomSource(card.route)
        // The subtitle the tile has no room for says what it is, as a card's does.
        .accessibilityLabel(card.subtitle.isEmpty ? card.title : "\(card.title), \(card.subtitle)")
        .contextMenu { CardMenu(card: card) }
    }
}

private struct SpeedDialDie: View {
    let cards: [Card]
    let size: CGFloat

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            if let card = cards.randomElement() { app.play(card) }
        } label: {
            ZStack {
                LinearGradient(colors: [theme.accent.opacity(0.35), theme.elevated], startPoint: .top, endPoint: .bottom)
                // A die's three, corner to corner.
                ForEach(-1...1, id: \.self) { step in
                    Circle()
                        .fill(theme.text.opacity(0.8))
                        .frame(width: size * 0.2, height: size * 0.2)
                        .offset(x: CGFloat(step) * size * 0.26, y: CGFloat(step) * size * 0.26)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: SpeedDialTile.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.97))
        .accessibilityLabel("Play one at random")
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? theme.text : theme.textDim)
                    .frame(width: 8, height: 8)
            }
        }
        .animation(Theme.normal, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}
