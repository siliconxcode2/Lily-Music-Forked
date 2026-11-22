import SwiftUI
import YTMCore

/// The playing title is bold rather than in the accent, which the artwork
/// behind Now Playing drowns.
struct QueueRow: View {
    let track: Track
    let current: Bool
    let recommended: Bool

    @Environment(\.theme) private var theme

    private static let art: CGFloat = 44

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: track.thumbnail, size: Self.art)
                .overlay {
                    if current {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.shadowDeep)
                            .overlay { PlayingEqualizer(colour: theme.onColour) }
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline.weight(current ? .bold : .medium))
                    .foregroundStyle(theme.text)
                HStack(spacing: 4) {
                    if recommended {
                        IconView(icon: .sparkle, size: 12, colour: theme.textSecondary)
                            .accessibilityLabel("Smart Shuffle pick")
                    }
                    Text(track.artistNames)
                        .font(.footnote)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(track.duration.map(Formatting.duration) ?? "")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.queueRow)
        // Every row stays one height for dragging, so the text stops growing where it would no longer fit.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
