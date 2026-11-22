import Foundation
import Testing
@testable import YTMAudio

struct EqualiserBandsTests {
    @Test func matchesWindows() {
        #expect(EqualiserBands.frequencies == [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000])
        #expect(EqualiserBands.maxGain == 12)
        #expect(EqualiserBands.presets.map(\.name) == ["Flat", "Bass boost", "Treble boost", "Vocal", "Rock", "Electronic", "Acoustic"])
        #expect(EqualiserBands.presets.allSatisfy { $0.gains.count == EqualiserBands.Gains.count })
        #expect(EqualiserBands.presets[3].gains == [-2, -2, -1, 1, 3, 4, 3, 2, 1, 0])
        #expect(EqualiserBands.q == 2.squareRoot(), "an octave")
    }

    @Test(arguments: [44_100.0, 48_000.0])
    func bandsReachTheirGain(rate: Double) {
        func db(_ peak: EqualiserBands.Peak, at hz: Double) -> Double { 10 * log10(peak.power(at: hz, rate: rate)) }
        for gain: Float in [-12, 6] {
            for centre in EqualiserBands.frequencies.map(Double.init) {
                let peak = EqualiserBands.Peak(centre: centre, gain: gain, rate: rate)
                #expect(abs(db(peak, at: centre) - Double(gain)) < 0.01, "\(centre) Hz")
            }
            let middle = EqualiserBands.Peak(centre: 1_000, gain: gain, rate: rate)
            #expect(abs(db(middle, at: 20)) < 0.1, "far bands untouched")
            #expect(abs(db(middle, at: 20_000)) < 0.1)
        }
    }

    @Test func leavesHeadroomForBoosts() {
        func headroom(_ gains: [Float]) -> Float {
            let filters = Equaliser().filters(for: EqualiserBands.clamped(gains), rate: 48_000)
            return -20 * log10(EqualiserBands.preamp(for: filters, rate: 48_000))
        }
        #expect(headroom([]) == 0)
        #expect(headroom(Array(repeating: -6, count: 10)) == 0)
        // Clamped to 12 dB, and overlapping boosts add up past any one band.
        #expect(abs(headroom([20]) - 12) < 0.1)
        #expect(headroom(Array(repeating: 12, count: 10)) > 12)
        #expect(headroom(EqualiserBands.presets[1].gains) >= 6)
    }

    @Test func bandsPastNyquistPassThrough() {
        let peak = EqualiserBands.Peak(centre: 16_000, gain: 12, rate: 22_050)
        #expect(peak.power(at: 1_000, rate: 22_050) == 1)
        let clamped = EqualiserBands.clamped([30, -30])
        #expect(clamped.indices.map { clamped[$0] } == [12, -12, 0, 0, 0, 0, 0, 0, 0, 0])
    }
}

extension EqualiserBands.Peak {
    /// The gain at `hz`, squared.
    func power(at hz: Double, rate: Double) -> Double {
        let w = 2 * Double.pi * hz / rate
        return power(cos(w), sin(w), cos(2 * w), sin(2 * w))
    }
}
