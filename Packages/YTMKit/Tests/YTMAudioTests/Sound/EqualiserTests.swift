import Foundation
import Testing
@testable import YTMAudio

/// Windows' eq.rs tests, the same sound in both channels where those run one.
struct EqualiserTests {
    private let flat = Array(repeating: Float(0), count: 10)

    private func tone(_ hz: Double, rate: Double = 48_000, frames: Int, level: Double) -> [Float] {
        (0..<frames).map { Float(sin(2 * .pi * hz * Double($0) / rate) * level) }
    }

    private func peak(_ samples: ArraySlice<Float>) -> Float {
        samples.map(abs).max() ?? 0
    }

    private func largestStep(_ samples: ArraySlice<Float>) -> Float {
        zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    }

    private func process(_ eq: inout Equaliser, _ samples: inout [Float], _ range: Range<Int>? = nil, rate: Double = 48_000) {
        let range = range ?? samples.indices
        Fixtures.mono(&samples) { left, right in
            eq.process(.init(rebasing: left[range]), .init(rebasing: right[range]), rate: rate)
        }
    }

    /// In blocks the size of a device callback.
    private func process(_ eq: inout Equaliser, _ samples: inout [Float], from start: Int, to end: Int, by size: Int, rate: Double = 48_000) {
        for first in stride(from: start, to: end, by: size) {
            process(&eq, &samples, first..<min(first + size, end), rate: rate)
        }
    }

    private func memory(_ eq: Equaliser) -> [Float] {
        eq.memory.indices.map { eq.memory[$0] }
    }

    @Test func offAndFlatRunNoFilters() {
        var eq = Equaliser()
        let music: ([Float], [Float]) = ([0.5, 0.125], [-0.25, 1])
        var (left, right) = music
        Fixtures.stereo(&left, &right) { eq.process($0, $1, rate: 48_000) }
        #expect(left == music.0 && right == music.1, "off")
        eq.target = EqualiserBands.clamped(flat)
        Fixtures.stereo(&left, &right) { eq.process($0, $1, rate: 48_000) }
        #expect(left == music.0 && right == music.1, "flat runs no filters")
    }

    @Test func boostsLeaveHeadroom() {
        var eq = Equaliser()
        var gains = flat
        (gains[1], gains[7]) = (20, -3)
        eq.target = EqualiserBands.clamped(gains)
        // A long 62 Hz tone at full scale stays within it once settled.
        var samples = tone(62, frames: 48_000, level: 1)
        process(&eq, &samples)
        let settled = peak(samples[24_000...])
        #expect(settled <= 1.05, "boost clamped to 12 dB and cancelled: \(settled)")
        #expect(settled > 0.7, "the boosted band stays near full scale: \(settled)")

        // Overlapping boosts add up, and the preamp covers their sum.
        for gains in [Array(repeating: 12, count: 10), EqualiserBands.presets[1].gains] {
            eq.target = EqualiserBands.clamped(gains)
            var tones = zip(tone(63, frames: 96_000, level: 0.5), tone(1_000, frames: 96_000, level: 0.5)).map { $0 + $1 }
            process(&eq, &tones)
            let settled = peak(tones[48_000...])
            #expect(settled <= 1.02, "\(gains) peaks at \(settled)")
        }
    }

    @Test func bandsPastNyquistPassThrough() {
        var eq = Equaliser()
        eq.target = EqualiserBands.clamped(EqualiserBands.presets[2].gains)
        var samples = tone(1_000, rate: 22_050, frames: 22_050, level: 1)
        process(&eq, &samples, from: 0, to: samples.count, by: 480, rate: 22_050)
        #expect(peak(samples[...]) <= 1.02, "the 16 kHz band stays stable at 22 kHz")
    }

    @Test func aGainChangeGlides() {
        var samples = tone(1_000, frames: 9_600, level: 0.25)
        var eq = Equaliser()
        eq.target = EqualiserBands.clamped(flat)
        // Up to the tone's peak, where a jump in level would show most.
        process(&eq, &samples, 0..<492)
        // A 12 dB boost far below lowers the tone by as much, through the preamp, fed in callbacks of uneven sizes.
        var gains = flat
        gains[0] = 12
        eq.target = EqualiserBands.clamped(gains)
        var (first, sizes) = (492, [441, 0, 100, 7])
        while first < samples.count {
            let size = min(sizes[0], samples.count - first)
            process(&eq, &samples, first..<first + size)
            first += size
            sizes = Array(sizes.dropFirst()) + [sizes[0]]
        }
        let largest = largestStep(samples[...])
        #expect(largest < 0.034, "no step: \(largest)")
        // 12 dB takes 75 ms, 3,600 frames: halfway there at 1,800.
        let halfway = peak(samples[(492 + 1_776)..<(492 + 1_824)])
        #expect((0.1..<0.16).contains(halfway), "\(halfway)")
        #expect(eq.playing.indices.map { eq.playing[$0] } == gains, "arrived")
        #expect(eq.preamp == EqualiserBands.preamp(for: eq.filters, rate: 48_000))
        let after = peak(samples[4_800...])
        #expect((0.055..<0.07).contains(after), "\(after)")
    }

    @Test func changingGainsKeepsTheFiltersMemory() {
        var eq = Equaliser()
        var six = flat
        six[0] = 6
        eq.target = EqualiserBands.clamped(six)
        var samples = Array(repeating: Float(0.5), count: 4_800)
        process(&eq, &samples)
        let kept = memory(eq)

        // Flat only between two callbacks: the filters never stopped.
        eq.target = EqualiserBands.clamped(flat)
        eq.target = EqualiserBands.clamped(Array(repeating: -1, count: 10))
        var none: [Float] = []
        process(&eq, &none)
        #expect(memory(eq) == kept, "a passing 0 dB keeps the memory")

        // Off or flat, they glide there and then rest.
        eq.target = EqualiserBands.clamped(six)
        process(&eq, &samples)
        eq.target = EqualiserBands.clamped(flat)
        process(&eq, &samples, 0..<32)
        #expect(eq.memory[0] != 0, "still gliding")
        // Arriving, then ringing out.
        process(&eq, &samples)
        process(&eq, &samples)
        var untouched: [Float] = [0.5, 0.5, 0.5, 0.5]
        process(&eq, &untouched)
        #expect(memory(eq).allSatisfy { $0 == 0 }, "leaves the filters at rest")
        #expect(untouched == [0.5, 0.5, 0.5, 0.5], "passes through")
    }

    @Test func filtersEachChannelAlike() {
        var (left, right) = (tone(100, frames: 4_800, level: 1), tone(100, frames: 4_800, level: 1))
        var eq = Equaliser()
        eq.target = EqualiserBands.clamped(EqualiserBands.presets[4].gains)
        Fixtures.stereo(&left, &right) { eq.process($0, $1, rate: 48_000) }
        #expect(left == right)
        #expect(left != tone(100, frames: 4_800, level: 1), "filtered")
    }

    @Test func turningOffRingsOutWithoutAClick() {
        var eq = Equaliser()
        var gains = flat
        gains[0] = 12
        eq.target = EqualiserBands.clamped(gains)
        // The slowest band's ringing, at full scale, is the hardest to end.
        var samples = tone(31, frames: 96_000, level: 1)
        process(&eq, &samples, from: 0, to: 48_000, by: 480)
        eq.target = EqualiserBands.clamped(flat)
        process(&eq, &samples, from: 48_000, to: 96_000, by: 480)
        #expect(memory(eq).allSatisfy { $0 == 0 }, "at rest")
        // A 31 Hz sine moves at most 0.004 a sample, the glide adding little.
        let largest = largestStep(samples[48_000...])
        #expect(largest < 0.006, "no click: \(largest)")
    }
}
