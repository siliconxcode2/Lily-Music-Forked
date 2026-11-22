import SwiftUI
import YTMCore

/// `TrackRow`s; an album's have no art.
struct TrackBones: View {
    let count: Int
    let art: Bool

    var body: some View {
        ForEach(0..<count, id: \.self) { index in
            HStack(spacing: Metrics.rowSpacing) {
                Bone(width: 14, height: 12)
                    .frame(width: Metrics.rowNumber)
                if art {
                    Bone(width: Metrics.rowArt, height: Metrics.rowArt)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Bone(width: Bone.length(index), height: 12)
                    Bone(width: Bone.length(index + 3) * 0.6, height: 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Metrics.rowPadding)
            .frame(height: Metrics.rowHeight)
            .padding(.horizontal, Metrics.pagePadding)
        }
    }
}

/// Titled sections in these layouts; nil is a song list.
struct SectionBones: View {
    let layouts: [CardLayout?]

    var body: some View {
        ForEach(layouts.indices, id: \.self) { index in
            SectionTitleBone()
            switch layouts[index] {
            case nil: TrackBones(count: 10, art: true)
            case .speedDial?: SpeedDialBones()
            case .grid?: GridBones()
            case .chips?: ChipBones()
            case .carousel?, .top?: CarouselBones()
            }
        }
    }
}

struct CarouselBones: View {
    /// Round art, as `CardView` draws artists.
    var round = false

    var body: some View {
        HStack(spacing: Metrics.cardGap) {
            ForEach(0..<3, id: \.self) { _ in
                CardBones(round: round)
                    .frame(width: Metrics.cardWidth)
            }
        }
        .padding(.horizontal, Metrics.pagePadding)
        // Runs off the edge; the zero minimum stops it widening the page.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .padding(.bottom, 8)
    }
}

struct SectionTitleBone: View {
    var body: some View {
        Bone(width: 160, height: 22)
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.top, 28)
            .padding(.bottom, 12)
            .frame(minHeight: Metrics.titleHeight, alignment: .bottom)
    }
}

/// As wide as it is given, as `CardView` is.
private struct CardBones: View {
    var round = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Bone(radius: round ? Metrics.cardWidth / 2 : Metrics.cardArtRadius)
                .aspectRatio(1, contentMode: .fit)
                .padding(.bottom, 4)
            Bone(height: 12)
                .padding(.trailing, 30)
            Bone(height: 10)
                .padding(.trailing, 78)
        }
    }
}

/// Adaptive columns size as `CardGrid`'s do.
struct GridBones: View {
    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Metrics.cardWidth), spacing: Metrics.cardGap, alignment: .top)],
            alignment: .leading,
            spacing: Metrics.cardGap * 2
        ) {
            ForEach(0..<6, id: \.self) { _ in CardBones() }
        }
        .padding(.horizontal, Metrics.pagePadding)
    }
}

/// `SpeedDial`'s first page and its dots.
private struct SpeedDialBones: View {
    var body: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Metrics.cardGap), count: 3), spacing: Metrics.cardGap) {
                ForEach(0..<9, id: \.self) { _ in
                    Bone(radius: 10)
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .frame(maxWidth: SpeedDial.maxPageWidth)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.pagePadding)
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in Bone(width: 8, height: 8, radius: 4) }
            }
        }
        .padding(.bottom, 8)
    }
}

/// `GenreGrid`'s tiles.
private struct ChipBones: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.chipMinWidth), spacing: Metrics.chipGap)], spacing: Metrics.chipGap) {
            ForEach(0..<8, id: \.self) { _ in Bone(height: Metrics.chipHeight, radius: 8) }
        }
        .padding(.horizontal, Metrics.pagePadding)
    }
}
