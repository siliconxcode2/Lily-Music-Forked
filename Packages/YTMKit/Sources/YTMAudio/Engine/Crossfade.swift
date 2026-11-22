import Accelerate
import Foundation

/// Worked out once both items' silences are known; `start` is a frame of the item fading out.
struct FadePlan {
    let from: Track
    let start: Int64
    let length: Int64
}

struct Fade {
    let from: Track
    let length: Int64
    var mixed: Int64 = 0

    var remaining: Int64 { length - mixed }
}

enum Crossfade {
    /// About -60 dBFS: quieter than this, a frame counts as silence.
    static let silence: Float = 0.001

    /// A stereo run of samples; a mono source gives the same channel twice.
    typealias Channels = (left: UnsafePointer<Float>, right: UnsafePointer<Float>)

    static func isSilent(_ channels: Channels, at frame: Int) -> Bool {
        abs(channels.left[frame]) < silence && abs(channels.right[frame]) < silence
    }

    static func leadingSilence(_ channels: Channels, count: Int) -> Int {
        (0..<count).first { !isSilent(channels, at: $0) } ?? count
    }

    /// The frame after the last that is not silent, or 0.
    static func soundEnd(_ channels: Channels, count: Int) -> Int {
        ((0..<count).last { !isSilent(channels, at: $0) }).map { $0 + 1 } ?? 0
    }

    /// Across a buffer, so a change of normalisation is heard as a glide, never a click.
    struct Ramp {
        let from: Float
        let to: Float
        let length: Int

        func at(_ frame: Int) -> Float {
            from + step * Float(min(frame, length))
        }

        var step: Float { (to - from) / Float(max(length, 1)) }
    }

    /// `offset` is both the frame of `out` and the frame of the ramp.
    static func copy(_ channels: Channels, gain: Ramp, count: Int, into out: UnsafePointer<UnsafeMutablePointer<Float>>, at offset: Int) {
        var step = gain.step
        // Each call moves `start` on, so it is set afresh for the second channel.
        var start = gain.at(offset)
        vDSP_vrampmul(channels.left, 1, &start, &step, out[0] + offset, 1, vDSP_Length(count))
        start = gain.at(offset)
        vDSP_vrampmul(channels.right, 1, &start, &step, out[1] + offset, 1, vDSP_Length(count))
    }

    /// Equal-power curves keep the loudness steady through the overlap, where linear ones dip midway.
    /// A nil side has ended and counts as silence; `offset` is also each side's frame of its ramp.
    static func mix(
        incoming: (channels: Channels, gain: Ramp)?,
        outgoing: (channels: Channels, gain: Ramp)?,
        count: Int,
        at position: Int64,
        of length: Int64,
        into out: UnsafePointer<UnsafeMutablePointer<Float>>,
        offset: Int
    ) {
        for frame in 0..<count {
            let angle = Double(position + Int64(frame)) / Double(max(length, 1)) * .pi / 2
            let fadeIn = Float(sin(angle))
            let fadeOut = Float(cos(angle))
            var left: Float = 0
            var right: Float = 0
            if let incoming {
                let gain = incoming.gain.at(offset + frame) * fadeIn
                left += incoming.channels.left[frame] * gain
                right += incoming.channels.right[frame] * gain
            }
            if let outgoing {
                let gain = outgoing.gain.at(offset + frame) * fadeOut
                left += outgoing.channels.left[frame] * gain
                right += outgoing.channels.right[frame] * gain
            }
            out[0][offset + frame] = left
            out[1][offset + frame] = right
        }
    }

    /// The sound after a start, seek or stall would otherwise step in and click.
    static func fadeIn(_ out: UnsafePointer<UnsafeMutablePointer<Float>>, count: Int, over length: Int) {
        let frames = min(count, length)
        for frame in 0..<frames {
            let gain = Float(frame + 1) / Float(length)
            out[0][frame] *= gain
            out[1][frame] *= gain
        }
    }
}
