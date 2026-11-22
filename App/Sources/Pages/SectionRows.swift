import SwiftUI
import YTMCore

/// The views are siblings in the page's lazy stack, so a long track list is
/// built only as it scrolls in.
struct SectionRows: View {
    let section: YTMCore.Section
    /// The page's width inside its padding.
    let width: CGFloat

    var body: some View {
        if !section.title.isEmpty {
            SectionHeader(title: section.title, more: section.more)
        }
        switch section {
        case .tracks(let tracks):
            if tracks.title.isEmpty {
                TrackColumns()
                    .padding(.horizontal, Metrics.pagePadding)
            }
            ForEach(tracks.tracks.indices, id: \.self) { index in
                SectionTrack(section: tracks, index: index)
            }
        case .cards(let cards):
            switch cards.layout {
            case .carousel:
                CarouselRow(cards: cards.cards)
                    .padding(.bottom, 8)
            case .grid where width > 0:
                CardGrid(cards: cards.cards, width: width)
            case .chips where width > 0:
                GenreGrid(cards: cards.cards, width: width)
            case .speedDial where width > 0:
                SpeedDial(cards: cards.cards, width: width)
            case .top:
                if let card = cards.cards.first {
                    TopResultCard(card: card)
                }
            case .grid, .chips, .speedDial:
                // Until the page's width is measured, so no card is sized to nothing.
                EmptyView()
            }
        }
    }
}

private struct SectionTrack: View {
    let section: TrackSection
    let index: Int

    @Environment(AppModel.self) private var app

    var body: some View {
        let track = section.tracks[index]
        TrackRow(
            track: track,
            number: section.numbered ? track.trackNumber ?? index + 1 : index + 1,
            numbered: section.numbered
        ) { app.player.play(section, at: index) }
        .modifier(EntryDrag(track: track, index: index))
        .padding(.horizontal, Metrics.pagePadding)
    }
}
