import Foundation
import Testing
@testable import YTMAudio

/// Windows' stereo.rs tests, but for its mono device, which the sound unit never has.
struct StereoTests {
    /// A second of the same frame, settled past any ramp; the last frame out.
    private func run(_ stereo: inout Stereo, _ frame: (Float, Float)) -> [Float] {
        var (left, right) = ([Float](repeating: frame.0, count: 48_000), [Float](repeating: frame.1, count: 48_000))
        Fixtures.stereo(&left, &right) { stereo.process($0, $1, rate: 48_000) }
        return [left[47_999], right[47_999]]
    }

    @Test func idleLeavesSamplesAlone() {
        let music = (0..<480).map { Float(sin(Double($0) * 0.37)) }
        var (left, right) = (music, music.reversed() as [Float])
        var stereo = Stereo()
        Fixtures.stereo(&left, &right) { stereo.process($0, $1, rate: 48_000) }
        #expect(left == music && right == music.reversed())
    }

    @Test func monoSumsTheSides() {
        var stereo = Stereo()
        stereo.mono = true
        #expect(run(&stereo, (0.5, 0.25)) == [0.375, 0.375])
    }

    @Test(arguments: [(0, [1, 1]), (-1, [1, 0]), (1, [0, 1]), (0.5, [0.5, 1]), (-0.25, [1, 0.75])] as [(Float, [Float])])
    func balanceLowersTheOtherSide(balance: Float, gains: [Float]) {
        var stereo = Stereo()
        stereo.balance = balance
        #expect(run(&stereo, (1, 1)) == gains)
    }

    @Test func crossfeedKeepsTheCentreAndLeaksTheSides() {
        var stereo = Stereo()
        stereo.crossfeed = true
        let centre = run(&stereo, (0.5, 0.5))
        #expect(abs(centre[0] - 0.5) < 1e-6 && abs(centre[1] - 0.5) < 1e-6, "\(centre)")

        // A steady sound on the left alone is low enough to be fed across.
        let side = run(&stereo, (0.5, 0))
        let feed = 20 * log10(side[1] / side[0])
        #expect(abs(feed + 4.5) < 0.05, "\(feed) dB")

        // Highs stay where they are.
        var left = (0..<9_600).map { Float($0 % 2 == 0 ? 0.5 : -0.5) }
        var right = [Float](repeating: 0, count: 9_600)
        Fixtures.stereo(&left, &right) { stereo.process($0, $1, rate: 48_000) }
        let (highs, leaked) = (left[4_800...].map(abs).max() ?? 0, right[4_800...].map(abs).max() ?? 1)
        #expect(highs > 0.45 && leaked < 0.05, "\(highs) \(leaked)")
    }

    @Test func turningOnRampsAndOffPassesThroughAgain() {
        var stereo = Stereo()
        stereo.mono = true
        var (left, right) = ([Float](repeating: 1, count: 4_800), [Float](repeating: 0, count: 4_800))
        Fixtures.stereo(&left, &right) { stereo.process($0, $1, rate: 48_000) }
        let largest = zip(left, left.dropFirst()).map { abs($1 - $0) }.max() ?? 1
        #expect(largest < 0.001, "no step")
        #expect(left[0] == 1 - 0.5 / 2_400, "a frame's step in")
        #expect(left[4_799] == 0.5 && right[4_799] == 0.5, "all the way in after 50 ms")

        stereo.mono = false
        _ = run(&stereo, (0.5, 0))
        let music: ([Float], [Float]) = ([0.3, 0.1], [-0.7, 0.9])
        (left, right) = music
        Fixtures.stereo(&left, &right) { stereo.process($0, $1, rate: 48_000) }
        #expect(left == music.0 && right == music.1, "idle again once ramped out")
    }
}
