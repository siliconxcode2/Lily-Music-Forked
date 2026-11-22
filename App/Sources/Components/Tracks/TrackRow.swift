import SwiftUI
import YTMCore

/// The menu button sits tight against the length, so the title keeps the room.
struct TrackRow: View {
    let track: Track
    let number: Int
    let numbered: Bool
    let play: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let playing = app.isPlaying(track)
        let length = track.duration.map(Formatting.duration)
        Button(action: play) {
            HStack(spacing: Metrics.rowSpacing) {
                Group {
                    if playing {
                        PlayingEqualizer()
                    } else {
                        Text(number, format: .number.grouping(.never))
                            .font(.subheadline)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
                .frame(width: Metrics.rowNumber)

                if !numbered {
                    ArtworkView(url: track.thumbnail, size: Metrics.rowArt)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(playing ? theme.accent : theme.text)
                    HStack(spacing: 4) {
                        DownloadBadge(videoId: track.id)
                        Text(track.artistNames)
                            .font(.footnote)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 0) {
                    // Room for the menu button laid over the row.
                    Color.clear.frame(width: Metrics.rowMore)
                    if let length {
                        Text(length)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: Metrics.rowDuration, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, Metrics.rowPadding)
            .padding(.vertical, 4)
            .frame(minHeight: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPress())
        .overlay(alignment: .trailing) {
            Menu {
                TrackMenu(track: track)
            } label: {
                IconView(icon: .more, size: 20, colour: theme.textSecondary)
                    .frame(width: Metrics.rowMore)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More")
            .padding(.trailing, Metrics.rowPadding + (length == nil ? 0 : Metrics.rowDuration))
        }
        .contextMenu { TrackMenu(track: track) }
    }
}

/// Apart so that play and pause redraw this alone rather than every row.
struct PlayingEqualizer: View {
    var colour: Color?

    @Environment(AppModel.self) private var app

    var body: some View {
        Equalizer(active: app.player.isPlaying, colour: colour)
    }
}

struct TrackColumns: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Metrics.rowSpacing) {
            Text("#")
                .frame(width: Metrics.rowNumber)
            Text("Title")
                .frame(maxWidth: .infinity, alignment: .leading)
            IconView(icon: .clock, size: 16, colour: theme.textSecondary)
                .frame(width: Metrics.rowDuration, alignment: .trailing)
        }
        .font(.subheadline)
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, Metrics.rowPadding)
        .frame(height: Metrics.columnsHeight)
        .overlay(alignment: .bottom) {
            theme.divider.frame(height: 1)
        }
        .padding(.bottom, 8)
        .accessibilityHidden(true)
    }
}
