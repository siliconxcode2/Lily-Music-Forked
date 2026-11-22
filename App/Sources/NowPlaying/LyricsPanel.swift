import SwiftUI
import YTMCore

/// The player loads lyrics only while this shows, which Now Playing tells it.
struct LyricsPanel: View {
    /// For a pull down past the top of the lines.
    let close: () -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        let player = app.player
        Group {
            switch player.lyrics {
            case .loading:
                // Lines of `LyricLine`'s height and spacing.
                VStack(alignment: .leading, spacing: 19) {
                    ForEach(0..<8, id: \.self) { Bone(width: Bone.length($0) * 1.5, height: 20) }
                }
                .padding(.horizontal, NowPlayingScreen.padding)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .skeleton()
            case .loaded(let lyrics):
                LyricsLines(lyrics: lyrics, close: close)
            case .idle, .unavailable, .failed:
                LyricsLines(lyrics: Lyrics(lines: [player.lyrics.message ?? ""]), close: close)
            }
        }
        // Each song starts afresh: at the top, following the singing.
        .id(player.current?.id)
    }
}

/// Scrolling by hand stops the following until a few seconds after the list comes to rest.
private struct LyricsLines: View {
    let lyrics: Lyrics
    let close: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var current: Int?
    @State private var position = ScrollPosition(idType: Int.self)
    @State private var phase = ScrollPhase.idle
    /// Whether the list keeps the line being sung in the middle.
    @State private var following = true
    /// Bumped each time the user lets go of the list, restarting the wait to follow again.
    @State private var released = 0

    private static let resumeAfter = Duration.seconds(3)

    var body: some View {
        let synced = lyrics.isSynced
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(lyrics.lines.indices, id: \.self) { index in
                    LyricLine(text: lyrics.lines[index], lit: !synced || index == current)
                        .onTapGesture { if synced { seek(to: index) } }
                        .accessibilityAddTraits(synced ? .isButton : [])
                }
                if !lyrics.source.isEmpty {
                    Text(lyrics.source)
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, NowPlayingScreen.padding)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($position, anchor: .center)
        .onScrollPhaseChange { old, new, context in
            scrolled(new)
            if pulledPastTop(old, new, context.geometry) { close() }
        }
        .task(id: released) {
            guard released > 0 else { return }
            try? await Task.sleep(for: Self.resumeAfter)
            guard !Task.isCancelled, phase == .idle else { return }
            following = true
            glide()
        }
        .background {
            if synced {
                LyricClock(lyrics: lyrics) { line in
                    current = line
                    glide()
                }
            }
        }
    }

    private func scrolled(_ new: ScrollPhase) {
        let byHand = phase == .interacting || phase == .decelerating
        phase = new
        switch new {
        case .interacting:
            following = false
        case .idle where byHand:
            released += 1
        default:
            break
        }
    }

    private func seek(to index: Int) {
        app.player.seek(to: lyrics.starts[index])
        current = index
        following = true
        glide()
    }

    /// Glides the lit line to the middle, unless the user has the list.
    private func glide() {
        guard following, let current else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.5)) { position.scrollTo(id: current, anchor: .center) }
    }
}

/// The line being sung, polled while playing and on a seek, which may come while paused; reported
/// only when it changes, so the lines redraw once a line rather than every frame.
private struct LyricClock: View {
    let lyrics: Lyrics
    let changed: (Int?) -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        let player = app.player
        TimelineView(.animation(minimumInterval: 0.05, paused: !player.isPlaying)) { _ in
            Color.clear
                .onChange(of: lyrics.lineIndex(at: player.currentTime), initial: true) { _, line in changed(line) }
        }
        // A seek lights its line whatever the pause.
        .onChange(of: player.lastSeek) { _, seek in changed(lyrics.lineIndex(at: seek.to)) }
    }
}

private struct LyricLine: View {
    let text: String
    let lit: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.title2.weight(.bold))
            .foregroundStyle(theme.text)
            .opacity(lit ? 1 : 0.5)
            .animation(Theme.normal, value: lit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}
