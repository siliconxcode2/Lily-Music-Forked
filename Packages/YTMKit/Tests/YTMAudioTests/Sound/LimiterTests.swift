import Foundation
import Testing
@testable import YTMAudio

struct LimiterTests {
    @Test func holdsPeaksAndLeavesTheRest() {
        var limiter = Limiter()
        let quiet = (0..<96).map { Float(sin(Double($0) * 0.3) * 0.9) }
        var (left, right) = (Array(quiet[..<48]), Array(quiet[48...]))
        Fixtures.stereo(&left, &right) { limiter.process($0, $1, rate: 48_000) }
        #expect(left + right == quiet, "within full scale, untouched")

        let loud = (0..<9_600).map { Float(sin(Double($0) * 0.3) * 4) }
        (left, right) = (stride(from: 0, to: loud.count, by: 2).map { loud[$0] }, stride(from: 1, to: loud.count, by: 2).map { loud[$0] })
        Fixtures.stereo(&left, &right) { limiter.process($0, $1, rate: 48_000) }
        #expect((left + right).allSatisfy { abs($0) <= 1 })
        #expect((left + right).contains { abs($0) > 0.99 }, "reaching full scale")
        #expect(limiter.limiting > 0.7, "holding it down")

        // A second of quiet lets go entirely, back to leaving it alone.
        (left, right) = ([Float](repeating: 0.5, count: 48_000), [Float](repeating: 0.5, count: 48_000))
        Fixtures.stereo(&left, &right) { limiter.process($0, $1, rate: 48_000) }
        #expect(limiter.limiting == 0)
        #expect(left.last == 0.5 && right.last == 0.5)
    }

    @Test func appliesEachTracksLoudness() {
        func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 0.001 }
        func gain(_ db: Float) -> Float { pow(10, -db / 20) }
        func normal(_ db: Float) -> Float { PlaybackEngine.normalised(gain(db), by: 1) }
        func quiet(_ db: Float) -> Float { PlaybackEngine.normalised(gain(db), by: 0.5) }
        #expect(normal(0) == 1, "unmeasured, taken as at the reference")
        #expect(near(normal(6), 0.501), "loud tracks turned down")
        #expect(near(normal(-3), 1.413), "quiet ones turned up")
        #expect(normal(-20) == PlaybackEngine.maxBoost, "but only so far")
        #expect(quiet(0) == 0.5)
        #expect(near(quiet(6), 0.251), "6 dB under Normal")
        #expect(near(quiet(-9), 1.409))
        #expect(quiet(-20) == PlaybackEngine.maxBoost)
        #expect(PlaybackEngine.normalised(gain(6), by: nil) == 1)
    }
}
