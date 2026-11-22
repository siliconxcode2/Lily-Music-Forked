import SwiftUI
import YTMCore
import YTMPlayback

struct TrackTitle: View {
    let track: Track
    /// Small and without the rating and download buttons or the next song, so the
    /// title has room beside play and next; large under the artwork.
    let compact: Bool

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                Button { app.openAlbum(of: track) } label: {
                    // Under the artwork there is room for a long title to wrap.
                    Text(track.title)
                        .font((compact ? Font.callout : .title2).weight(.bold))
                        .foregroundStyle(theme.text)
                        .lineLimit(compact ? 1 : 2)
                }
                .disabled(track.album == nil)
                Button { app.openArtist(of: track) } label: {
                    Text(track.artistNames)
                        .font(compact ? .footnote : .callout)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                .disabled(track.firstArtistId == nil)
                if !compact {
                    UpNextLine()
                }
            }
            .buttonStyle(PressScale(scale: 0.98))
            .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                RatingButtons(track: track)
            }
        }
    }
}

/// The song after this one, wrapping to the first with repeat-all.
private struct UpNextLine: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let queue = app.player.queue
        let mode = app.settings.value.repeatMode
        // With repeat-one, or one song on repeat-all, the next song is this one again.
        let next = mode == .one || queue.count < 2 ? nil : queue.peekNext(repeat: mode)
        // Always laid out, so the artwork above keeps its size as the line comes and goes.
        Text(verbatim: next.map { "Next: \($0.title)  \u{2022}  \($0.artistNames)" } ?? " ")
            .font(.footnote)
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)
            .accessibilityHidden(next == nil)
    }
}

private struct RatingButtons: View {
    let track: Track

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        if app.isSignedIn, app.settings.value.ratingButtons {
            let rating = app.player.rating
            button(rating == .dislike ? .thumbDownFilled : .thumbDown, on: rating == .dislike, label: "Dislike") {
                app.rate(track, .dislike)
            }
            button(rating == .like ? .thumbUpFilled : .thumbUp, on: rating == .like, label: "Like") {
                app.rate(track, .like)
            }
        }
        TrackDownloadButton(track: track)
    }

    private func button(_ icon: Icon, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        IconButton(icon: icon, size: 40, iconSize: 22, colour: on ? theme.text : theme.textSecondary, action: action)
            .accessibilityLabel(label)
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}
