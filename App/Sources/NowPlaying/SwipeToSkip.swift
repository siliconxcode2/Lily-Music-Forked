import SwiftUI
import UIKit

/// The artwork follows a sideways swipe and springs back; far or fast enough,
/// it skips to the next song or back to the last, as Apple Music's does.
struct SwipeToSkip: ViewModifier {
    /// How far a slow swipe must go to skip.
    private static let distance: CGFloat = 90
    /// How fast a short flick must be to skip.
    private static let speed: CGFloat = 600

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var skips = 0

    func body(content: Content) -> some View {
        content
            // Resisting more the further it goes, so it never leaves the screen.
            .offset(x: offset)
            .rotationEffect(.degrees(reduceMotion ? 0 : Double(offset) / 40))
            .gesture(SidewaysPan(changed: { offset = $0 * 0.6 }, ended: ended))
            .sensoryFeedback(.impact(weight: .light), trigger: skips)
            .accessibilityAction(named: "Next song") { app.player.next() }
            .accessibilityAction(named: "Previous song") { app.player.previous() }
    }

    private func ended(_ translation: CGFloat, _ velocity: CGFloat) {
        let forward = translation < -Self.distance || velocity < -Self.speed
        let back = translation > Self.distance || velocity > Self.speed
        if forward { app.player.next() }
        if back { app.player.previous() }
        if forward || back { skips += 1 }
        withAnimation(Theme.bouncy) { offset = 0 }
    }
}

/// A pan that begins only when the finger moves more sideways than up or down,
/// so the pager's vertical swipes and Now Playing's swipe to close are left alone.
private struct SidewaysPan: UIGestureRecognizerRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed:
            changed(translation)
        case .ended, .cancelled, .failed:
            ended(translation, recognizer.velocity(in: recognizer.view).x)
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.5
        }
    }
}
