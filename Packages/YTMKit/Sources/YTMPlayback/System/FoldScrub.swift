import Foundation

/// Seeking by folding iPhone Duo's hinge. Once the half-open hinge has rested a
/// moment, each step it opens further skips ahead and each step it folds skips
/// back. Steps are taken only as the hinge comes to rest again, so folding the
/// phone shut or opening it flat, which pass steps on the way, never seek.
public struct FoldScrub: Sendable {
    public static let degreesPerStep = 15.0
    public static let secondsPerStep = 10.0
    /// A turn of more steps than this is the phone being folded into another
    /// pose, which may have armed it on a slow start, rather than a scrub.
    static let maxSteps = 3
    /// Still for this long before it arms, so folding into the pose isn't read as a scrub.
    static let armAfter: TimeInterval = 1
    /// Still for this long after a turn before it seeks.
    public static let seekAfter: TimeInterval = 0.4
    /// Movement within this of where the hinge stopped is a wobble; measured
    /// from there, not the last reading, so a slow drift adds up to a turn.
    static let stillness = 2.0

    /// Where the hinge last stopped, and since when.
    private var still: (angle: Double, since: TimeInterval)?
    /// Where the hinge rested as it armed or last seeked; steps count from it.
    private var anchor: Double?

    public init() {}

    /// A hinge reading, its angle nil unless it is partly open. Returns
    /// whether it turned rather than wobbled, as only a turn puts off a seek.
    @discardableResult
    public mutating func hinge(angle: Double?, at time: TimeInterval) -> Bool {
        guard let angle else {
            self = FoldScrub()
            return false
        }
        if let still, abs(angle - still.angle) <= Self.stillness { return false }
        if anchor == nil, let still, time - still.since >= Self.armAfter {
            anchor = still.angle
        }
        still = (angle, time)
        return true
    }

    /// Called `seekAfter` past a turn: the seconds to seek by, once the hinge
    /// has rested a whole step or more from where it armed or last seeked.
    public mutating func settle(at time: TimeInterval) -> Double? {
        guard let anchor, let still, time - still.since >= Self.seekAfter else { return nil }
        let steps = Int((still.angle - anchor) / Self.degreesPerStep)
        guard steps != 0 else { return nil }
        // From where it stopped rather than a whole number of steps on, so a
        // wobble there doesn't tip it into the next.
        self.anchor = still.angle
        return abs(steps) > Self.maxSteps ? nil : Double(steps) * Self.secondsPerStep
    }
}
