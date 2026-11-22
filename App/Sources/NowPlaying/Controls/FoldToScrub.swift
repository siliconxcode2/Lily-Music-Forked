import SwiftUI
import YTMPlayback

/// Folding the half-open phone seeks (`FoldScrub`), with a tick for each seek.
/// Only held like a book: stood like a laptop, the phone rests on a desk.
struct FoldToScrub: ViewModifier {
    let isSideBySide: Bool

    @Environment(AppModel.self) private var app
    @State private var scrub = FoldScrub()
    @State private var settling: Task<Void, Never>?
    @State private var seeks = 0

    /// Read here rather than by Now Playing, so a change to any setting re-runs only this.
    private var isEnabled: Bool {
        app.settings.value.foldToScrub && isSideBySide
    }

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content
                .onHingeChange(isEnabled: isEnabled) { _, new in reading(new.hinge) }
                .sensoryFeedback(.selection, trigger: seeks)
                .onChange(of: isEnabled) {
                    settling?.cancel()
                    scrub = FoldScrub()
                }
                // So closing Now Playing mid-turn doesn't seek once it has gone.
                .onDisappear { settling?.cancel() }
        } else {
            content
        }
    }

    @available(iOS 27.1, *)
    private func reading(_ hinge: DeviceHinge?) {
        let angle = hinge.flatMap { $0.status == .partiallyOpen ? $0.angle.degrees : nil }
        // A wobble leaves the wait for the hinge to rest running.
        guard scrub.hinge(angle: angle, at: ProcessInfo.processInfo.systemUptime) else { return }
        settling?.cancel()
        settling = Task {
            try? await Task.sleep(for: .seconds(FoldScrub.seekAfter))
            guard !Task.isCancelled, let seconds = scrub.settle(at: ProcessInfo.processInfo.systemUptime) else { return }
            // Seeking keeps itself within the song.
            app.player.seek(to: app.player.currentTime + seconds)
            seeks += 1
        }
    }
}

/// Notes a hinge, so Settings offers fold to scrub only on a phone that folds.
struct HingeCheck: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange(isEnabled: !app.hasHinge) { _, new in
                if new.hinge != nil { app.hasHinge = true }
            }
        } else {
            content
        }
    }
}
