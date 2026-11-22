import AVFoundation

/// Runs on its own serial queue, never the main actor, and keeps only a few seconds of
/// sound in memory, refilled as buffers play.
actor PlaybackEngine {
    /// Stamped with the `play` or `stop` it follows, so the player can drop stale events.
    struct Stamped: Sendable {
        let session: UInt64
        let event: AudioEvent
    }

    enum Output: Sendable {
        case device
        case offline(sampleRate: Double)
    }

    nonisolated let clock = PlaybackClock()
    nonisolated let queue = DispatchSerialQueue(label: "Lily.audio", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    static let bufferSeconds = 0.5
    static let aheadSeconds = 3.5
    /// Long enough for the mixer's volume ramp to reach silence.
    static let pauseRamp = DispatchTimeInterval.milliseconds(60)
    /// After this long paused or stopped, the output stops so the device can sleep.
    static let idleAfter = DispatchTimeInterval.seconds(30)
    /// The fade-in after a start, seek or stall: about one device callback.
    static let fadeInSeconds = 0.01

    /// Made on the engine's queue at first use, as both reach for the system.
    lazy var graph = makeGraph()
    lazy var cache = AudioCache(cacheLocation)
    private let output: Output
    private let cacheLocation: AudioCache.Location
    let source: any ByteSource
    let events: AsyncStream<Stamped>.Continuation
    private var observers: [any NSObjectProtocol] = []

    var session: UInt64 = 0
    var heard: Track?
    /// The one heard, or the next once it follows on the same player.
    var producing: Track?
    var next: Track?
    var warmed: Warmed?
    /// The level items are normalised to, as a gain on YouTube's reference loudness (0.5 is 6 dB under), or nil for none.
    var normalise: Float? = 1
    var pauseOnUnplug = true
    /// The crossfade into `next`, in seconds, or 0 to follow without a gap.
    var nextFade = 0.0
    var plan: FadePlan?
    var fade: Fade?
    /// The item heard has ended, and the next is still opening.
    var awaitingNext = false

    /// Oldest first.
    var scheduled: [Scheduled] = []
    var aheadFrames = 0
    /// Frames scheduled since the player last started, its timeline.
    var playerFrames: Int64 = 0
    /// Bumped as the player is stopped, so completions of its old buffers are ignored.
    var generation = 0
    var playerRunning = false
    var fadeInNext = true
    var paused = false
    var buffering = false
    /// Bumped by every pause and resume, so a stale delayed stop does nothing.
    var pauseToken = 0

    struct Scheduled {
        let track: Track
        /// The item frame of its first frame.
        let first: Int64
        let frames: Int
        /// Its first frame on the player's timeline.
        var start: Int64 = 0
    }

    init(output: Output, source: any ByteSource, cache: AudioCache.Location, events: AsyncStream<Stamped>.Continuation) {
        self.output = output
        self.source = source
        cacheLocation = cache
        self.events = events
    }

    private func makeGraph() -> AudioGraph {
        guard case .offline(let rate) = output else { return AudioGraph() }
        return AudioGraph(offlineFormat: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
    }

    /// Runs `operation` on the engine's queue, in the order sent.
    nonisolated func send(_ operation: @escaping @Sendable (isolated PlaybackEngine) -> Void) {
        queue.async { self.assumeIsolated(operation) }
    }

    func emit(_ event: AudioEvent) {
        events.yield(Stamped(session: session, event: event))
    }

    // MARK: Commands

    func play(_ item: AudioItem, from seconds: Double, paused: Bool, session: UInt64) {
        self.session = session
        observeOutputChanges()
        clear()
        self.paused = paused
        graph.setSilenced(paused)
        guard let track = open(item, at: seconds, announcingStart: true) else { return }
        // Sent after the download's first job, so the output wakes while the
        // first range is in flight rather than after it.
        if !paused { send { _ = $0.graph.start() } }
        heard = track
        producing = track
        clock.pin(seconds, since: nil)
        describeHeard()
        // Said again for the new item, as the player drops what came before it.
        buffering = false
        updateBuffering()
    }

    func setNext(_ item: AudioItem?, fade seconds: Double, session: UInt64) {
        guard session == self.session, heard != nil else { return }
        dropNext()
        next = item.flatMap { open($0, at: 0, announcingStart: false) }
        nextFade = seconds
        // The item heard ended waiting for the next, which is gone.
        if next == nil, awaitingNext {
            awaitingNext = false
            finish()
        }
    }

    func seek(to seconds: Double, session: UInt64) {
        guard session == self.session, let heard else { return }
        // A seek lands in the item heard, so a next that already follows it
        // is dropped, and the controller queues it again.
        if let switched = producing, switched !== heard {
            keepWarm(switched)
            emit(.nextDropped)
        }
        producing = heard
        fade = nil
        plan = nil
        awaitingNext = false
        heard.seek(to: max(seconds, 0))
        clock.pin(max(seconds, 0), since: nil)
        restartPlayer()
    }

    func pause() {
        paused = true
        pauseToken += 1
        let token = pauseToken
        graph.setSilenced(true)
        queue.asyncAfter(deadline: .now() + Self.pauseRamp) { [self] in
            assumeIsolated { engine in
                guard engine.paused, engine.pauseToken == token, engine.playerRunning else { return }
                engine.graph.player.pause()
                engine.playerRunning = false
                engine.clock.hold()
            }
        }
        stopOutputWhenIdle()
        updateBuffering()
    }

    func resume() {
        paused = false
        pauseToken += 1
        graph.setSilenced(false)
        if heard != nil, !graph.engine.isRunning {
            // The output stopped while paused, idle or interrupted and took the
            // player's schedule with it, so it is remade from where the sound stopped.
            seek(to: clock.position(), session: session)
        } else if !scheduled.isEmpty, !playerRunning {
            startPlayer()
        }
        updateBuffering()
    }

    /// `keepingOutput` for a change of song: a stopped output lets iOS suspend the app in
    /// the background while it fetches that song.
    func stop(session: UInt64, keepingOutput: Bool = false) {
        self.session = session
        clear()
        clock.pin(0, since: nil)
        describeHeard()
        updateBuffering()
        if !keepingOutput { stopOutputWhenIdle() }
    }

    func setLevel(_ level: Float) {
        graph.setLevel(level)
    }

    func setEqualiser(enabled: Bool, gains: [Float]) {
        graph.setEqualiser(enabled: enabled, gains: gains)
    }

    func setStereo(crossfeed: Bool, mono: Bool, balance: Float) {
        graph.setStereo(crossfeed: crossfeed, mono: mono, balance: balance)
    }

    /// Between two speeds other than 1x the change is live; to or from 1x the output is reconnected,
    /// so the sound carries on from where it was, as after a device change. Paused, `resume` does that.
    func setSpeed(_ speed: Double) {
        clock.setSpeed(speed)
        guard graph.setSpeed(speed), heard != nil, !paused else { return }
        seek(to: clock.position(), session: session)
    }

    func cacheSize() -> Int64 {
        cache.size()
    }

    func clearCache() {
        cache.clear()
    }

    /// For after a media services reset, when the old graph no longer reaches the device.
    /// Drops anything playing; the mute, sound settings and speed carry over.
    func rebuildGraph() {
        clear()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        let old = graph
        old.engine.stop()
        graph = makeGraph()
        graph.adoptSettings(of: old)
    }

    func shutDown() {
        clear()
        warmed?.task.cancel()
        warmed = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        graph.engine.stop()
        events.finish()
    }

    // MARK: Output

    /// A device change stops the engine, so it reconnects at the new format and carries on.
    private func observeOutputChanges() {
        guard observers.isEmpty else { return }
        observers = [
            NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: graph.engine, queue: nil
            ) { [weak self] _ in
                self?.send { $0.outputChanged() }
            },
        ]
        #if os(iOS)
        // Straight to the engine's queue, not through the main actor's, so the pause lands before, or close
        // behind, a device change restarting the sound on the speaker.
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: nil
        ) { [weak self] notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init)
            guard reason == .oldDeviceUnavailable else { return }
            self?.send { $0.unplugged() }
        })
        #endif
    }

    /// Ahead of the controller, whose own pause still follows with the toast.
    private func unplugged() {
        guard pauseOnUnplug, !paused, heard != nil else { return }
        pause()
    }

    private func outputChanged() {
        graph.connectOutput()
        guard heard != nil else { return }
        seek(to: clock.position(), session: session)
    }

    func stopOutputWhenIdle() {
        let token = pauseToken
        let generation = generation
        queue.asyncAfter(deadline: .now() + Self.idleAfter) { [self] in
            assumeIsolated { engine in
                let stopped = engine.heard == nil && engine.generation == generation
                guard engine.pauseToken == token, engine.paused || stopped else { return }
                engine.graph.engine.stop()
            }
        }
    }
}
