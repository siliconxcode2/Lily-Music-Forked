/// Keeps peaks within full scale: each frame's gain drops at once to what keeps its loudest channel at 1, then
/// rises back linearly, so it lands exactly on idle and leaves samples already within full scale untouched.
struct Limiter {
    /// How long it takes to let go of a full reduction, in seconds; smaller ones go in proportion, so a 3 dB dip
    /// comes back in about 0.3 s.
    static let releaseSeconds: Float = 1

    /// How far the gain is down from 1, at 0 while idle.
    var limiting: Float = 0

    mutating func process(_ left: UnsafeMutableBufferPointer<Float>, _ right: UnsafeMutableBufferPointer<Float>, rate: Double) {
        let step = 1 / (Self.releaseSeconds * Float(max(rate, 1)))
        for frame in 0..<min(left.count, right.count) {
            let peak = max(abs(left[frame]), abs(right[frame]))
            limiting = max(limiting - step, 0)
            if peak * (1 - limiting) > 1 {
                limiting = 1 - 1 / peak
            }
            if limiting > 0 {
                // Clamped too, as `1 - (1 - 1 / peak)` can round past it.
                left[frame] = min(max(left[frame] * (1 - limiting), -1), 1)
                right[frame] = min(max(right[frame] * (1 - limiting), -1), 1)
            }
        }
    }
}
