import Foundation
import Testing
@testable import YTMAudio

private final class Stereo {
    let count: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let pointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    init(_ samples: [Float]) {
        count = samples.count
        left = .allocate(capacity: max(count, 1))
        right = .allocate(capacity: max(count, 1))
        left.initialize(from: samples, count: count)
        right.initialize(from: samples, count: count)
        pointers = .allocate(capacity: 2)
        pointers.initialize(from: [left, right], count: 2)
    }

    deinit {
        left.deallocate()
        right.deallocate()
        pointers.deallocate()
    }

    var channels: Crossfade.Channels { (UnsafePointer(left), UnsafePointer(right)) }
    var output: UnsafePointer<UnsafeMutablePointer<Float>> { UnsafePointer(pointers) }
    var samples: (left: [Float], right: [Float]) {
        (Array(UnsafeBufferPointer(start: left, count: count)), Array(UnsafeBufferPointer(start: right, count: count)))
    }
}

struct CrossfadeTests {
    private func mix(_ incoming: [Float]?, _ outgoing: [Float]?, gains: (Float, Float) = (1, 1), from start: Int64 = 0, length: Int64) -> [Float] {
        let count = incoming?.count ?? outgoing?.count ?? 0
        let out = Stereo(Array(repeating: 0, count: count))
        let new = incoming.map(Stereo.init)
        let old = outgoing.map(Stereo.init)
        let ramps = (Crossfade.Ramp(from: gains.0, to: gains.0, length: count), Crossfade.Ramp(from: gains.1, to: gains.1, length: count))
        Crossfade.mix(
            incoming: new.map { ($0.channels, ramps.0) }, outgoing: old.map { ($0.channels, ramps.1) },
            count: count, at: start, of: length, into: out.output, offset: 0
        )
        #expect(out.samples.left == out.samples.right, "channels fade together")
        return out.samples.left
    }

    @Test func fadesWithEqualPower() {
        let samples = mix(Array(repeating: 1, count: 1_000), Array(repeating: 1, count: 1_000), length: 1_000)
        #expect(samples[0] == 1, "starts on the outgoing item alone")
        let angle = 0.5 * Double.pi / 2
        // Uncorrelated tracks sum by power, so the curves' squares sum to 1.
        #expect(abs(samples[500] - Float(sin(angle) + cos(angle))) < 1e-6)
        #expect(samples[999] > 0.99 && samples[999] < 1.01, "ends near the incoming item alone")
    }

    @Test func mixesAcrossPiecesAsInOne() {
        let incoming = (0..<960).map { Float(cos(Double($0) * 0.03)) }
        let outgoing = (0..<960).map { Float(sin(Double($0) * 0.01)) }
        let whole = mix(incoming, outgoing, gains: (1, 0.5), length: 960)
        let pieces = stride(from: 0, to: 960, by: 122).flatMap { start -> [Float] in
            let end = min(start + 122, 960)
            return mix(Array(incoming[start..<end]), Array(outgoing[start..<end]), gains: (1, 0.5), from: Int64(start), length: 960)
        }
        #expect(pieces == whole)
    }

    @Test func fadesOutOverSilenceOnceTheIncomingItemEnds() {
        let samples = mix(nil, Array(repeating: 0.5, count: 4), gains: (1, 2), length: 4)
        #expect(samples[0] == 1, "the outgoing item at its own gain")
        #expect(samples[3] < samples[0])
    }

    @Test func hearsSilenceBelowTheThresholdOnly() {
        let quiet = Stereo([0, -0.000_5, 0, 0.01, 0, 0])
        #expect(Crossfade.isSilent(quiet.channels, at: 1))
        #expect(!Crossfade.isSilent(quiet.channels, at: 3))
        #expect(Crossfade.leadingSilence(quiet.channels, count: 6) == 3)
        #expect(Crossfade.soundEnd(quiet.channels, count: 6) == 4)
        #expect(Crossfade.soundEnd(quiet.channels, count: 3) == 0)
    }

    @Test func glidesFromOneGainToAnotherAcrossPieces() {
        let ones = Stereo(Array(repeating: 1, count: 4))
        let out = Stereo(Array(repeating: 0, count: 4))
        let ramp = Crossfade.Ramp(from: 1, to: 0.5, length: 4)
        Crossfade.copy(ones.channels, gain: ramp, count: 2, into: out.output, at: 0)
        Crossfade.copy(ones.channels, gain: ramp, count: 2, into: out.output, at: 2)
        #expect(out.samples.left == [1, 0.875, 0.75, 0.625] && out.samples.right == out.samples.left)
        #expect(ramp.at(4) == 0.5, "where the next buffer starts")
    }

    @Test func fadesInFromSilence() {
        let buffer = Stereo(Array(repeating: 1, count: 8))
        Crossfade.fadeIn(buffer.output, count: 8, over: 4)
        #expect(buffer.samples.left == [0.25, 0.5, 0.75, 1, 1, 1, 1, 1])
        #expect(buffer.samples.right == buffer.samples.left)
    }
}
