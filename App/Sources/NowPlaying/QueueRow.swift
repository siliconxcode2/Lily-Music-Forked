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
                    .font(.system(size: 14, weight: current ? .bold : .medium))
                    .foregroundStyle(theme.text)
                HStack(spacing: 4) {
                    if recommended {
                        IconView(icon: .sparkle, size: 12, colour: theme.textSecondary)
                            .accessibilityLabel("Smart Shuffle pick")
                    }
                    Text(track.artistNames)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(track.duration.map(Formatting.duration) ?? "")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.queueRow)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
