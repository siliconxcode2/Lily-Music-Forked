import Foundation
import Observation
import os
import YTMAudio
import YTMCore

/// Call `start()` once at launch. A result that arrives after the player has
/// moved on is dropped. The position is never observed: read `currentTime`
/// from a `TimelineView`. Everything else that changes is observable.
@MainActor @Observable public final class PlayerController {
    /// How often the sound is checked while playing, for gapless queueing,
    /// scrobbling and Now Playing's position.
    nonisolated static let tick = Duration.milliseconds(250)
    static let maxConsecutiveFailures = 3

    /// Change it through the player's methods.
    public internal(set) var queue = Queue<Track>()
    /// The song shown, also while it loads, once stopped and when restored.
    public internal(set) var current: Track?
    /// Whether the player means to play, through loading and stalls: the
    /// play button.
    public internal(set) var isPlaying = false {
        didSet { if isPlaying != oldValue { updateTicking() } }
    }
    /// Loading the song, or stalled waiting on the network while playing.
    public internal(set) var isBuffering = false
    /// The song's length in seconds; 0 until known.
    public internal(set) var duration = 0.0
    /// The playing song's lyrics. They load while `showsLyrics` is set.
    public internal(set) var lyrics = LyricsState.idle
    /// Set while lyrics are on screen, so they load for each song.
    public var showsLyrics = false {
        didSet { if showsLyrics, !oldValue { loadLyrics() } }
    }
    /// How the account rated the song playing; `.none` signed out.
    public internal(set) var rating = Rating.none {
        didSet { nowPlaying?.setLike(isLiked: rating == .like, enabled: signedIn) }
    }
    /// Nil while the song loads.
    public internal(set) var stream: ResolvedStream?
    /// Whether the account plays Premium streams, as found so far.
    public internal(set) var premiumStatus = PremiumStatus.unknown
    /// Bumped when the account's library changes from here, so the app can
    /// load cached library pages afresh.
    public internal(set) var libraryRevision = 0
    /// The last seek, so views that pull `currentTime` only while playing
    /// still catch one made while paused.
    public internal(set) var lastSeek = Seek(count: 0, to: 0)

    /// Messages for the user. One consumer, which must live as long as the
    /// player: cancelling the loop that reads it ends the stream for good.
    public nonisolated let toasts: AsyncStream<String>

    /// Where the song has got to, in seconds. Cheap; not observed.
    public var currentTime: Double {
        playback.itemID != nil ? audio.currentTime : playback.heldPosition
    }

    /// How far the song has downloaded from where it plays, from 0 to 1. Not observed, so
    /// pull it as `currentTime` is.
    public var bufferedFraction: Double {
        playback.itemID != nil ? audio.bufferedFraction : 0
    }

    // MARK: Collaborators

    @ObservationIgnored let music: any MusicService
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let history: LocalHistory
    @ObservationIgnored let audio: any AudioOutput
    @ObservationIgnored let store: FileStore
    @ObservationIgnored let chooser: StreamChooser
    @ObservationIgnored let recorder: PlayRecorder
    public let downloads: Downloads
    @ObservationIgnored var nowPlaying: NowPlayingCenter?
    @ObservationIgnored private var audioSession: AudioSessionController?
    @ObservationIgnored private let toastSink: AsyncStream<String>.Continuation

    // MARK: State, never observed

    @ObservationIgnored var playback = PlaybackState()
    @ObservationIgnored var gapless = GaplessScheduler()
    @ObservationIgnored var prefetcher = StreamPrefetcher()
    @ObservationIgnored var smart = SmartShuffle()
    @ObservationIgnored var songVersions = SongVersionSwapper()
    @ObservationIgnored var signedIn = false
    /// The settings last put into effect, to tell what a change changed.
    @ObservationIgnored var applied: Settings?
    @ObservationIgnored let sessionSaving = Debounce()
    /// The song whose lyrics are shown or loading.
    @ObservationIgnored var lyricsFor: String?
    /// Nil for songs without lyrics. Failures are never kept.
    @ObservationIgnored var lyricsCache: [String: Lyrics?] = [:]
    static let lyricsCacheLimit = 32
    /// Songs whose lyrics are being fetched ahead, so each is asked for once.
    @ObservationIgnored var lyricsAhead: Set<String> = []
    /// Bumped as the song changes or is rated, so a stale rating isn't shown.
    @ObservationIgnored var ratingGeneration: UInt64 = 0
    @ObservationIgnored private var itemSerial: UInt64 = 0
    @ObservationIgnored private var hasStarted = false

    // MARK: Tasks, cancelled on replacement and with the player

    @ObservationIgnored var listening: [Task<Void, Never>] = []
    @ObservationIgnored private var ticking: Task<Void, Never>?
    /// The playing song's stream being resolved.
    @ObservationIgnored var resolving: Task<Void, Never>?
    /// The next song's stream being resolved to queue it in the engine.
    @ObservationIgnored var queueing: Task<Void, Never>?
    /// A radio carrying the queue on: the one after a song a radio started
    /// from, or the one queued as the last song starts.
    @ObservationIgnored var extending: Task<Void, Never>?
    /// A radio fetched once the queue has played out, to move on to.
    @ObservationIgnored var autoplay: Task<Void, Never>?
    /// What a page or card asked to play, while its tracks load.
    @ObservationIgnored var pendingPlay: Task<Void, Never>?
    /// The rest of a long playlist being added after its first batch started.
    @ObservationIgnored var continuing: Task<Void, Never>?
    @ObservationIgnored var lyricsLoad: Task<Void, Never>?
    @ObservationIgnored var ratingLoad: Task<Void, Never>?
    /// The wait before opening a song again after its connection dropped.
    @ObservationIgnored var reopenWait: Task<Void, Never>?

    public convenience init(
        api: YTMusic = .shared, settings: SettingsStore = .shared, history: LocalHistory = .shared,
        lastFM: LastFM = .shared, audio: AudioPlayer = AudioPlayer()
    ) {
        self.init(music: api, settings: settings, history: history, lastFM: lastFM, audio: audio, store: .shared, system: true)
    }

    /// `system` hooks up Now Playing, the remote commands and the audio
    /// session; tests leave them out.
    init(
        music: any MusicService, settings: SettingsStore, history: LocalHistory, lastFM: any Scrobbling,
        audio: any AudioOutput, store: FileStore, system: Bool
    ) {
        self.music = music
        self.settings = settings
        self.history = history
        self.audio = audio
        self.store = store
        chooser = StreamChooser(music: music)
        recorder = PlayRecorder(history: history, music: music, lastFM: lastFM)
        (toasts, toastSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
        downloads = Downloads(music: music, chooser: chooser, settings: settings, history: history, store: store, toasts: toastSink)
        if system {
            nowPlaying = NowPlayingCenter(player: self)
            audioSession = AudioSessionController(player: self)
        }
        listening = [
            Task { [weak self, events = audio.events] in
                for await event in events {
                    self?.handle(event)
                }
            },
            Task { [weak self, revoked = lastFM.accessRevoked] in
                for await _ in revoked {
                    self?.say("Last.fm no longer allows access. Connect it again in Settings.")
                }
            },
        ]
    }

    isolated deinit {
        for task in listening + [ticking, resolving, queueing, extending, autoplay, pendingPlay, continuing, lyricsLoad, ratingLoad, reopenWait] {
            task?.cancel()
        }
        toastSink.finish()
    }

    /// Shows the last launch's song, paused. Its network work waits until
    /// `launchLoad` returns, so it doesn't compete with what the launch is
    /// waiting on. Later calls do nothing.
    public func start(after launchLoad: @escaping @Sendable () async -> Void = {}) async {
        guard !hasStarted else { return }
        hasStarted = true
        await settings.load()
        await history.load()
        await downloads.load()
        signedIn = await music.isSignedIn
        chooser.seed(known: settings.value.premiumAccount, none: settings.value.noPremium)
        premiumStatus = chooser.status
        apply(settings.value)
        followSettings()
        let restored = await restoreSession()
        let rating = ratingGeneration
        Task { [weak self] in
            await launchLoad()
            self?.warmUp(restored, rating: rating)
            self?.downloads.release()
        }
    }

    // MARK: The tick

    private func updateTicking() {
        ticking?.cancel()
        ticking = nil
        guard isPlaying else { return }
        ticking = Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(for: Self.tick, tolerance: .milliseconds(50))
                } catch {
                    return
                }
                self?.onTick()
            }
        }
    }

    func onTick() {
        syncPremiumStatus()
        guard playback.started else { return }
        let position = audio.currentTime
        recorder.heard(position: position, length: playback.duration, speed: audio.speed, reporting: reportsToYouTube)
        updateGapless(at: position)
        nowPlaying?.keep(elapsed: position, advancing: isAdvancing)
    }

    // MARK: Shared helpers

    var repeatMode: RepeatMode { settings.value.repeatMode }

    /// Nothing is loaded for the song shown.
    var isStopped: Bool { !playback.started && !playback.loading }

    /// 0 while the engine has no song.
    var enginePosition: Double { playback.itemID != nil ? audio.currentTime : 0 }

    var isAdvancing: Bool { isPlaying && playback.started && !playback.stalled }

    func updateBuffering() {
        let buffering = playback.loading || (playback.stalled && isPlaying)
        if isBuffering != buffering { isBuffering = buffering }
    }

    /// `position` is for a seek the engine has yet to carry out.
    func publishPlayback(at position: Double? = nil) {
        nowPlaying?.setPlayback(playing: isPlaying, advancing: isAdvancing, elapsed: position ?? currentTime)
    }

    func say(_ message: String) {
        Logger.playback.info("\(message, privacy: .public)")
        toastSink.yield(message)
    }

    func activateAudioSession() {
        audioSession?.activate()
    }

    /// Captures the settings and account now, so the work can run, and run
    /// again, off the main actor.
    func resolver(for videoId: String) -> @Sendable () async throws -> ResolvedStream {
        let (chooser, quality, signedIn) = (chooser, settings.value.quality, signedIn)
        let wantPremium = signedIn && quality == .high && playback.forceFree != videoId
        let reopening = playback.reopening(videoId)
        return { try await chooser.resolve(videoId: videoId, wantPremium: wantPremium, signedIn: signedIn, quality: quality, reopening: reopening) }
    }

    /// A downloaded song plays its file even online, until the file fails to play; then it streams.
    func localStream(_ videoId: String) -> StreamPrefetcher.Prefetched? {
        guard playback.forceFree != videoId, let stream = downloads.stream(for: videoId) else { return nil }
        return .init(stream: stream, resolvedAt: .now, epoch: prefetcher.epoch)
    }

    /// Each item has its own ID, so a song queued after itself is told apart.
    /// A URL googlevideo refuses partway is refreshed only for the same file,
    /// so the download carries on from the same byte, with the issuing
    /// client's headers, as googlevideo checks them. The engine can't import
    /// YTMCore, so every URL, refreshed ones too, passes the allowlist here.
    func audioItem(for track: Track, stream: ResolvedStream) throws(YTMError) -> AudioItem {
        itemSerial += 1
        return try Self.audioItem(
            id: "\(track.id)#\(itemSerial)", videoId: track.id, stream: stream,
            chooser: chooser, quality: settings.value.quality, signedIn: signedIn, local: downloads.holds(stream.url)
        )
    }

    /// `local` for a downloaded song's own file, the one URL the allowlist doesn't cover.
    nonisolated static func audioItem(
        id: String, videoId: String, stream: ResolvedStream, chooser: StreamChooser, quality: AudioQuality, signedIn: Bool,
        local: Bool
    ) throws(YTMError) -> AudioItem {
        guard local || HostAllowlist.allows(stream.url) else { throw Self.blocked }
        // YouTube's loudness against its reference level, turned down or up while normalising.
        let loudness = -Float(stream.loudnessDb ?? 0)
        // The client of the URL last given, cut off should its fresh one be refused too.
        let client = OSAllocatedUnfairLock(initialState: stream.client)
        return AudioItem(
            id: id, url: stream.url, headers: stream.headers, contentLength: stream.contentLength,
            cacheKey: DownloadedSong.key(videoId: videoId, itag: stream.itag), loudnessDB: loudness
        ) { again in
            let fresh = try await chooser.refresh(
                videoId: videoId, wasPremium: stream.isPremium, itag: stream.itag,
                cutOff: again ? client.withLock { $0 } : nil, signedIn: signedIn, quality: quality
            )
            client.withLock { $0 = fresh.client }
            guard fresh.itag == stream.itag, fresh.contentLength == stream.contentLength else { throw Self.otherFile }
            guard HostAllowlist.allows(fresh.url) else { throw Self.blocked }
            return (url: fresh.url, headers: fresh.headers)
        }
    }

    private nonisolated static let blocked = YTMError(.refused, "The app blocked a request to a site it doesn't use.")
    private nonisolated static let otherFile = YTMError(.unplayable, "YouTube offered a different file partway through the song.")

    /// Also drops what was on its way for the old queue.
    func replaceQueue(with tracks: [Track], start: Int, shuffle: Bool) {
        playback.failures = 0
        // Chosen afresh, a song that dropped starts over.
        if playback.reopen != nil {
            playback.reopen = nil
            playback.resume = nil
        }
        queue.set(items: tracks, start: start, shuffle: shuffle)
        smart.reset()
        for task in [extending, autoplay, pendingPlay, continuing] { task?.cancel() }
        playback.extending = false
    }
}

/// Counted, so seeking to the same place again still counts as a change.
public struct Seek: Equatable, Sendable {
    public let count: Int
    /// In seconds.
    public let to: Double
}
