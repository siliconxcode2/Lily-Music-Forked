import Foundation

/// Ten peaking filters in the sound unit, as Windows runs them in the device callback, so a change is heard at
/// once. Gains glide to a new setting, and once flat the filters ring out before resting.
struct Equaliser {
    typealias Gains = EqualiserBands.Gains

    /// The gains set, flat while off.
    var target = Gains(repeating: 0)
    /// The gains the filters are at, gliding toward `target`.
    private(set) var playing = Gains(repeating: 0)
    /// Copied from `EqualiserBands.frequencies` up front, as the render thread may not touch an array.
    private let centres = InlineArray<10, Double> { Double(EqualiserBands.frequencies[$0]) }
    /// The rate the filters were made for.
    private var rate = 0.0
    /// Every band's filter, so the memory keeps its layout as gains change.
    private(set) var filters = InlineArray<10, EqualiserBands.Peak>(repeating: EqualiserBands.Peak(centre: 0, gain: 0, rate: 0))
    /// Each channel's z1 and z2 for each band. Kept through a change of gains, as zeroing it mid-song would click.
    private(set) var memory = InlineArray<40, Float>(repeating: 0)
    /// Lowers the whole signal by the peak of the combined boost, so the bands cannot push the music past full
    /// scale.
    private(set) var preamp: Float = 1
    /// Frames the filters still run once glided to flat, so what rings in their memory dies away rather than
    /// being cut off with a click.
    private var ringing = 0

    /// Glided to flat, or never moved from it.
    private var isFlat: Bool {
        for band in playing.indices where playing[band] != 0 || target[band] != 0 {
            return false
        }
        return true
    }

    func filters(for gains: Gains, rate: Double) -> InlineArray<10, EqualiserBands.Peak> {
        InlineArray { EqualiserBands.Peak(centre: centres[$0], gain: gains[$0], rate: rate) }
    }

    mutating func process(_ left: UnsafeMutableBufferPointer<Float>, _ right: UnsafeMutableBufferPointer<Float>, rate: Double) {
        // Idle filters are kept at rest, as resuming with stale music in their memory thumps.
        if isFlat && ringing == 0 || rate == 0 {
            memory = InlineArray(repeating: 0)
            return
        }
        if rate != self.rate {
            filters = filters(for: playing, rate: rate)
            preamp = EqualiserBands.preamp(for: filters, rate: rate)
            self.rate = rate
        }
        let frames = min(left.count, right.count)
        let start = playing
        let perFrame = EqualiserBands.glide / Float(rate)
        // Frames until every band arrives, in whole blocks.
        var gliding = 0
        var furthest: Float = 0
        for band in start.indices {
            furthest = max(furthest, abs(start[band] - target[band]))
        }
        if furthest > 0 {
            let block = EqualiserBands.block
            gliding = min((Int((furthest / perFrame).rounded(.up)) + block - 1) / block * block, frames)
        }
        var (ratio, endPreamp): (Float, Float) = (1, preamp)
        if gliding > 0 {
            let end = Self.toward(start, target, by: perFrame * Float(gliding))
            endPreamp = EqualiserBands.preamp(for: filters(for: end, rate: rate), rate: rate)
            // A steady ratio moves the preamp evenly in dB, as the gains move.
            ratio = pow(endPreamp / preamp, 1 / Float(gliding))
        }
        var (first, done) = (0, 0)
        while first < frames {
            let last = min(first + EqualiserBands.block, frames)
            var step: Float = 1
            if done < gliding {
                done += last - first
                let gains = Self.toward(start, target, by: perFrame * Float(done))
                for band in gains.indices where gains[band] != playing[band] {
                    filters[band] = EqualiserBands.Peak(centre: centres[band], gain: gains[band], rate: rate)
                }
                playing = gains
                step = ratio
            }
            for frame in first..<last {
                preamp *= step
                left[frame] = filter(left[frame], channel: 0) * preamp
                right[frame] = filter(right[frame], channel: 1) * preamp
            }
            first = last
        }
        // Exactly, past the ramp's rounding.
        preamp = endPreamp
        // A tenth of a second takes even a full-scale bass note's ringing down to about -60 dB.
        ringing = isFlat ? max(ringing - (frames - gliding), 0) : Int(rate) / 10
        for index in memory.indices {
            memory[index] = memory[index].flushed
        }
    }

    /// Transposed direct form II, with b1 = a1.
    private mutating func filter(_ sample: Float, channel: Int) -> Float {
        var x = sample
        for band in filters.indices {
            let f = filters[band]
            let z = (channel * filters.count + band) * 2
            let y = f.b0 * x + memory[z]
            memory[z] = f.a1 * (x - y) + memory[z + 1]
            memory[z + 1] = f.b2 * x - f.a2 * y
            x = y
        }
        return x
    }

    /// Each gain moved up to `by` dB toward its target, landing on it exactly.
    private static func toward(_ from: Gains, _ to: Gains, by: Float) -> Gains {
        Gains { band in
            let gap = to[band] - from[band]
            return abs(gap) <= by ? to[band] : from[band] + (gap < 0 ? -by : by)
        }
    }
}

extension Float {
    /// Filter memory this small is flushed, as denormal floats would slow every sample once the music goes quiet;
    /// a filter that blew up anyway is put back at rest rather than left sending infinities to the device.
    var flushed: Float { abs(self) < 1e-20 || !isFinite ? 0 : self }
}
