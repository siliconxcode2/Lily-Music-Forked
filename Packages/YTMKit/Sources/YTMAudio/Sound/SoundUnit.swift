import AVFoundation
import os

/// After the mixer, as Windows runs them in the device callback, so a change is heard at once rather than after
/// the few seconds already scheduled. In-process, so offline renders in tests run it too.
final class SoundUnit: AUAudioUnit {
    /// Registered once, before the first unit is made.
    static let component: AudioComponentDescription = {
        // 'lsnd' by 'Lily'.
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: 0x6c73_6e64, componentManufacturer: 0x4c69_6c79,
            componentFlags: 0, componentFlagsMask: 0
        )
        AUAudioUnit.registerSubclass(SoundUnit.self, as: description, name: "Lily: Sound", version: 1)
        return description
    }()

    /// Allocated once for the unit's life, as the engine stops and starts again around it and the filters' state
    /// carries on through that, as on Windows.
    private let render = UnsafeMutablePointer<Render>.allocate(capacity: 1)
    /// What the engine last asked for, taken up by the render thread whenever the lock is free, so it never waits.
    private let pending = UnsafeMutablePointer<Pending>.allocate(capacity: 1)
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private let input: AUAudioUnitBus
    private let output: AUAudioUnitBus
    private lazy var inputArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [input])
    private lazy var outputArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [output])

    struct Pending: Sendable {
        /// Clamped, and flat while off.
        var equaliser = EqualiserBands.Gains(repeating: 0)
        var crossfeed = false
        var mono = false
        /// From -1, the left side alone, to 1, the right.
        var balance: Float = 0
        /// Bumped by a seek or a load, as Windows resets its output then.
        var resets: UInt64 = 0
    }

    /// The render thread's own: written elsewhere only while the unit is not rendering.
    private struct Render {
        var rate = 0.0
        var resets: UInt64 = 0
        var equaliser = Equaliser()
        var stereo = Stereo()
        var limiter = Limiter()
        /// The input is pulled into these, one channel after the other, `capacity` frames each.
        var samples: UnsafeMutablePointer<Float>?
        var capacity = 0
        let pulled = AudioBufferList.allocate(maximumBuffers: 2)

        mutating func take(_ wanted: Pending) {
            equaliser.target = wanted.equaliser
            (stereo.crossfeed, stereo.mono, stereo.balance) = (wanted.crossfeed, wanted.mono, wanted.balance)
            if wanted.resets != resets {
                resets = wanted.resets
                // What follows a seek or load starts from no limiting, and with no lows of what came before.
                limiter.limiting = 0
                stereo.reset()
            }
        }

        mutating func process(_ left: UnsafeMutableBufferPointer<Float>, _ right: UnsafeMutableBufferPointer<Float>) {
            equaliser.process(left, right, rate: rate)
            stereo.process(left, right, rate: rate)
            // Last, after the boost, the equaliser and a crossfade's sum.
            limiter.process(left, right, rate: rate)
        }
    }

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        input = try AUAudioUnitBus(format: format)
        output = try AUAudioUnitBus(format: format)
        render.initialize(to: Render())
        pending.initialize(to: Pending())
        lock.initialize(to: os_unfair_lock())
        try super.init(componentDescription: componentDescription, options: options)
    }

    deinit {
        render.pointee.samples?.deallocate()
        free(render.pointee.pulled.unsafeMutablePointer)
        render.deinitialize(count: 1)
        render.deallocate()
        pending.deinitialize(count: 1)
        pending.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    var wanted: Pending {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return pending.pointee
    }

    func change(_ body: (inout Pending) -> Void) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        body(&pending.pointee)
    }

    override var inputBusses: AUAudioUnitBusArray { inputArray }
    override var outputBusses: AUAudioUnitBusArray { outputArray }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let frames = Int(maximumFramesToRender)
        if frames > render.pointee.capacity {
            render.pointee.samples?.deallocate()
            render.pointee.samples = .allocate(capacity: frames * 2)
            render.pointee.capacity = frames
        }
        render.pointee.rate = output.format.sampleRate
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let (render, pending, lock) = (render, pending, lock)
        return { _, timestamp, frameCount, _, outputData, _, pullInput in
            guard let pullInput else { return kAudioUnitErr_NoConnection }
            let frames = Int(frameCount)
            let capacity = render.pointee.capacity
            guard frames <= capacity, let samples = render.pointee.samples else { return kAudioUnitErr_TooManyFramesToProcess }
            let pulled = render.pointee.pulled
            for index in pulled.indices {
                pulled[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frameCount * 4, mData: samples + index * capacity)
            }
            var flags = AudioUnitRenderActionFlags()
            let status = pullInput(&flags, timestamp, frameCount, 0, pulled.unsafeMutablePointer)
            guard status == noErr else { return status }
            // Into the output's own buffers, or, where it has none, handed ours.
            let out = UnsafeMutableAudioBufferListPointer(outputData)
            for index in out.indices where index < pulled.count {
                if let into = out[index].mData, let from = pulled[index].mData, into != from {
                    into.copyMemory(from: from, byteCount: Int(pulled[index].mDataByteSize))
                } else if out[index].mData == nil {
                    out[index].mData = pulled[index].mData
                }
                out[index].mDataByteSize = pulled[index].mDataByteSize
            }
            if os_unfair_lock_trylock(lock) {
                let wanted = pending.pointee
                os_unfair_lock_unlock(lock)
                render.pointee.take(wanted)
            }
            guard out.count == 2, let left = out[0].mData, let right = out[1].mData else { return noErr }
            render.pointee.process(
                UnsafeMutableBufferPointer(start: left.assumingMemoryBound(to: Float.self), count: frames),
                UnsafeMutableBufferPointer(start: right.assumingMemoryBound(to: Float.self), count: frames)
            )
            return noErr
        }
    }
}
