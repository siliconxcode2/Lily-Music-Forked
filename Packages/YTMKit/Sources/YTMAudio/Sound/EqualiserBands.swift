import Foundation

public struct EqualiserBands {
    /// Each band's centre in Hz, an octave apart.
    public static let frequencies: [Float] = [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    /// Either way, in dB.
    public static let maxGain: Float = 12
    /// Each band's gain in dB, from low to high.
    public static let presets: [(name: String, gains: [Float])] = [
        ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Bass boost", [6, 6, 4, 2, 1, 0, 0, 0, 0, 0]),
        ("Treble boost", [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        ("Vocal", [-2, -2, -1, 1, 3, 4, 3, 2, 1, 0]),
        ("Rock", [4, 4, 2, 0, -2, -1, 1, 3, 4, 4]),
        ("Electronic", [5, 5, 3, 1, 0, -1, 1, 3, 4, 4]),
        ("Acoustic", [3, 3, 2, 1, 1, 1, 2, 2, 2, 2]),
    ]

    /// One gain per band, in fixed storage, as the render thread may not allocate.
    typealias Gains = InlineArray<10, Float>

    /// How wide the peaks are: an octave.
    static let q = 2.squareRoot()
    /// How fast a gain glides to a new setting, in dB a second: the whole 12 dB in 75 ms, so a slider's steps
    /// never click.
    static let glide: Float = 160
    /// Frames between new coefficients while gliding.
    static let block = 32

    /// Missing gains are 0.
    static func clamped(_ gains: [Float]) -> Gains {
        Gains { gains.indices.contains($0) ? min(max(gains[$0], -maxGain), maxGain) : 0 }
    }

    /// The preamp that cancels the peak of the combined boost. Neighbouring bands overlap and their boosts add,
    /// so the peak is found on a sixth-octave grid from 20 Hz to below Nyquist.
    static func preamp(for filters: InlineArray<10, Peak>, rate: Double) -> Float {
        // 1000^(1/63): 64 points from 20 Hz to 20 kHz.
        let step = 1.115_884
        let top = rate * 0.45
        var (hz, peak) = (20.0, 1.0)
        for _ in 0..<64 {
            // The same for every band, so worked out once: this runs on the render thread through a glide.
            let w = 2 * Double.pi * min(hz, top) / rate
            let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
            var power = 1.0
            for band in filters.indices {
                power *= filters[band].power(c1, s1, c2, s2)
            }
            peak = max(peak, power.squareRoot())
            hz *= step
        }
        return Float(1 / peak)
    }

    /// RBJ's Audio EQ Cookbook peaking filter, normalised by a0. A peaking filter's b1 equals its a1, so only a1
    /// is kept.
    struct Peak {
        var b0: Float = 1, b2: Float = 0, a1: Float = 0, a2: Float = 0

        init(centre: Double, gain: Float, rate: Double) {
            // A centre at or past Nyquist makes the filter unstable, which would turn the music into full-scale
            // noise; such a band passes through.
            guard centre < rate * 0.45 else { return }
            let a = pow(10, Double(gain) / 40)
            let w0 = 2 * Double.pi * centre / rate
            let alpha = sin(w0) / (2 * EqualiserBands.q)
            let a0 = 1 + alpha / a
            b0 = Float((1 + alpha * a) / a0)
            b2 = Float((1 - alpha * a) / a0)
            a1 = Float(-2 * cos(w0) / a0)
            a2 = Float((1 - alpha / a) / a0)
        }

        /// The gain at w, squared, from the cosines and sines of w and 2w and the transfer function
        /// H(e^jw) = (b0 + b1 e^-jw + b2 e^-2jw) / (1 + a1 e^-jw + a2 e^-2jw).
        func power(_ c1: Double, _ s1: Double, _ c2: Double, _ s2: Double) -> Double {
            func part(_ k0: Float, _ k1: Float, _ k2: Float) -> Double {
                let (k0, k1, k2) = (Double(k0), Double(k1), Double(k2))
                let (re, im) = (k0 + k1 * c1 + k2 * c2, k1 * s1 + k2 * s2)
                return re * re + im * im
            }
            return part(b0, a1, b2) / part(1, a1, a2)
        }
    }
}
