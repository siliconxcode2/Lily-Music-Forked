import AVFoundation

/// Sample-exact gains and fades are applied to the buffers before scheduling, so one player is enough.
/// The mixer smooths every volume change over about 25 ms, so pausing and muting never click.
final class AudioGraph {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    private let mixer = AVAudioMixerNode()
    private let varispeed = AVAudioUnitVarispeed()
    private let sound = AVAudioUnitEffect(audioComponentDescription: SoundUnit.component)
    private(set) var playerFormat: AVAudioFormat?
    private var level: Float = 1
    private var silenced = false
    private var speed = 1.0

    /// Renders into `offlineFormat` on demand rather than to the device, for tests.
    init(offlineFormat: AVAudioFormat? = nil) {
        if let offlineFormat {
            try? engine.enableManualRenderingMode(.offline, format: offlineFormat, maximumFrameCount: 4_096)
        }
        for node in [player, mixer, varispeed, sound] {
            engine.attach(node)
        }
        connectOutput()
    }

    /// Call again after the output device changes.
    func connectOutput() {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000, channels: 2)
        // Plain nodes at a standard format: the engine has no reason to refuse. At 1x the varispeed
        // stays out of the path, so the sound is exactly the decoder's.
        if speed == 1 {
            _ = connect(mixer, to: sound, format: format)
        } else {
            _ = connect(mixer, to: varispeed, format: format)
            _ = connect(varispeed, to: sound, format: format)
        }
        _ = connect(sound, to: engine.outputNode, format: format)
    }

    /// The player must be stopped, so a change of rate leaves a short gap. False if the engine refused.
    func connectPlayer(_ format: AVAudioFormat) -> Bool {
        guard connect(player, to: mixer, format: format) else { return false }
        playerFormat = format
        return true
    }

    /// iOS 26 has only the raising form. It is safe with what arrives here, standard float stereo at a
    /// positive rate, but raises if anything other than a mixer input changes while the engine runs.
    private func connect(_ node: AVAudioNode, to next: AVAudioNode, format: AVAudioFormat?) -> Bool {
        guard #available(iOS 27, *) else {
            // After a device change the engine may already have been restarted; the seek that follows starts it again.
            if engine.isRunning, !(next is AVAudioMixerNode) { engine.stop() }
            engine.connect(node, to: next, fromBus: 0, toBus: 0, format: format)
            return true
        }
        return (try? engine.connectNode(node, to: next, fromBus: 0, toBus: 0, format: format)) != nil
    }

    /// False if the player refused. On iOS 26, play() raises unless the player is connected and the
    /// engine running; the engine can stop between `start` and here when the system takes the output.
    func play() -> Bool {
        guard #available(iOS 27, *) else {
            guard engine.isRunning else { return false }
            player.play()
            return true
        }
        return (try? player.playAudio()) != nil
    }

    func start() -> Bool {
        guard !engine.isRunning else { return true }
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    /// 0 muted, 1 otherwise.
    func setLevel(_ level: Float) {
        self.level = level
        applyVolume()
    }

    func setSilenced(_ silenced: Bool) {
        self.silenced = silenced
        applyVolume()
    }

    /// Glides to the new gains; off, it glides to flat and rings out before resting.
    func setEqualiser(enabled: Bool, gains: [Float]) {
        let gains = enabled ? EqualiserBands.clamped(gains) : EqualiserBands.Gains(repeating: 0)
        unit?.change { $0.equaliser = gains }
    }

    /// Balance from -1, the left side alone, to 1, the right. Each change ramps in over 50 ms.
    func setStereo(crossfeed: Bool, mono: Bool, balance: Float) {
        let balance = min(max(balance, -1), 1)
        unit?.change { ($0.crossfeed, $0.mono, $0.balance) = (crossfeed, mono, balance) }
    }

    /// True if the varispeed joined or left the path, which stops the engine to reconnect it.
    func setSpeed(_ speed: Double) -> Bool {
        let rewired = (speed == 1) != (self.speed == 1)
        self.speed = speed
        varispeed.rate = Float(speed)
        guard rewired else { return false }
        engine.stop()
        connectOutput()
        return true
    }

    /// For a seek or a load.
    func resetSound() {
        unit?.change { $0.resets &+= 1 }
    }

    func adoptSettings(of old: AudioGraph) {
        setLevel(old.level)
        if let wanted = old.unit?.wanted { unit?.change { $0 = wanted } }
        _ = setSpeed(old.speed)
    }

    /// The host time is nil when the device gives none.
    func renderedSample() -> (sample: Int64, hostTime: UInt64?)? {
        guard let nodeTime = player.lastRenderTime, let time = player.playerTime(forNodeTime: nodeTime) else { return nil }
        return (time.sampleTime, nodeTime.isHostTimeValid ? nodeTime.hostTime : nil)
    }

    /// Always ours, as the component is registered to it.
    private var unit: SoundUnit? {
        guard #available(iOS 27, macOS 27, *) else { return sound.auAudioUnit as? SoundUnit }
        return sound.withAUAudioUnit { copy $0 } as? SoundUnit
    }

    private func applyVolume() {
        mixer.outputVolume = silenced ? 0 : level
    }
}
