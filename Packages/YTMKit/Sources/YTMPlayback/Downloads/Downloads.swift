import Foundation
import Network
import Observation
import os
import YTMAudio
import YTMCore

/// Each song is resolved just before it downloads, as stream URLs expire. What the phone holds is worked
/// out afresh from what is wanted, so removing one thing never takes a song something else still holds.
@MainActor @Observable public final class Downloads {
    static let simultaneous = 2
    static let retryAfter = Duration.seconds(60)

    var index = DownloadIndex() {
        didSet {
            // A finished song changes only `songs`, which none of these depend on.
            guard index.singles != oldValue.singles || index.collections != oldValue.collections
                || index.smart != oldValue.smart else { return }
            wanted = index.wanted
            wantedIDs = Set(wanted.map(\.id))
            collected = Set(index.collections.flatMap { $0.tracks.map(\.id) })
        }
    }
    /// From 0 to 1, for each song downloading.
    private(set) var progress: [String: Double] = [:] {
        didSet { if isActive == progress.isEmpty { isActive.toggle() } }
    }
    /// The app asks iOS for background time while this is true. Stored rather than worked out from
    /// `progress`, so views reading it don't redraw with every step.
    public private(set) var isActive = false {
        // However downloads stop, as the background time then ends and a suspended app may be killed.
        didSet { if !isActive { saveIfPending() } }
    }
    /// Nil until the system first reports, so nothing downloads before then.
    public private(set) var online: Bool?
    /// Cellular or a hotspot, for the Wi-Fi only setting.
    private(set) var metered = false
    /// Tried again when the app or the network comes back.
    var failed: Set<String> = []
    /// Albums and playlists whose song lists are loading.
    var fetching: Set<Route> = []

    @ObservationIgnored private(set) var wanted: [Track] = []
    @ObservationIgnored private(set) var wantedIDs: Set<String> = []
    /// Songs in any downloaded album or playlist.
    @ObservationIgnored private var collected: Set<String> = []
    /// The serial stops a cancelled or replaced download from reporting.
    @ObservationIgnored private var active: [String: (serial: Int, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var serial = 0
    /// The phone is full: nothing more starts until something is removed or the app returns.
    @ObservationIgnored private var outOfRoom = false
    /// A pause after a network failure the system didn't report as offline.
    @ObservationIgnored private var resting: Task<Void, Never>?
    @ObservationIgnored var refreshing: Task<Void, Never>?
    @ObservationIgnored private var watching: Task<Void, Never>?
    /// Until the launch's own requests settle, so downloads don't slow Home or the first song.
    @ObservationIgnored private(set) var held = true
    /// Finished songs save the index at most every 10 s, as it holds every song and a big download
    /// would otherwise rewrite it once a song.
    @ObservationIgnored private let indexSaving = Debounce(after: .seconds(10))

    @ObservationIgnored let music: any MusicService
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let history: LocalHistory
    @ObservationIgnored let toasts: AsyncStream<String>.Continuation
    @ObservationIgnored private let chooser: StreamChooser
    @ObservationIgnored private let store: FileStore
    @ObservationIgnored private let audio: AudioDownloader
    @ObservationIgnored private let monitor = NWPathMonitor()

    init(
        music: any MusicService, chooser: StreamChooser, settings: SettingsStore, history: LocalHistory,
        store: FileStore, toasts: AsyncStream<String>.Continuation
    ) {
        self.music = music
        self.chooser = chooser
        self.settings = settings
        self.history = history
        self.store = store
        self.toasts = toasts
        audio = AudioDownloader(directory: store.downloads.appending(path: "Audio", directoryHint: .isDirectory)) {
            Proxy.configurations
        }
    }

    isolated deinit {
        monitor.cancel()
        for task in [watching, refreshing, resting] { task?.cancel() }
        for download in active.values { download.task.cancel() }
    }

    /// A song that failed reads as not downloaded, so its menu offers to try again.
    public func state(of videoId: String) -> DownloadState {
        if index.songs[videoId] != nil { return .downloaded }
        if let fraction = progress[videoId] { return .downloading(fraction) }
        return wantedIDs.contains(videoId) && !failed.contains(videoId) ? .waiting : .none
    }

    /// A song an album or playlist holds is removed with it, not on its own.
    public func canRemove(_ videoId: String) -> Bool {
        wantedIDs.contains(videoId) && !collected.contains(videoId)
    }

    public func download(_ track: Track) {
        if !wantedIDs.contains(track.id) {
            failed.remove(track.id)
            index.singles.insert(track, at: 0)
            changed()
        } else if failed.remove(track.id) != nil {
            reconcile()
        } else {
            return
        }
        announce(track.title)
    }

    public func remove(_ track: Track) {
        index.singles.removeAll { $0.id == track.id }
        index.smart.removeAll { $0.id == track.id }
        changed()
    }

    /// Smart picks come back at the next daily refresh.
    public func removeAll() {
        index.singles = []
        index.collections = []
        index.smart = []
        changed()
    }

    /// Nothing downloaded or on its way.
    public var isEmpty: Bool { wanted.isEmpty && index.songs.isEmpty }

    public var songCount: Int { index.songs.count }

    public var bytes: Int64 {
        index.songs.values.reduce(0) { $0 + $1.stream.contentLength }
    }

    /// Lets downloads start, once the launch has settled.
    func release() {
        held = false
        resume()
    }

    /// Retries failed songs and a full phone, and refreshes collections and smart picks when due.
    public func resume() {
        if !failed.isEmpty { failed.removeAll() }
        outOfRoom = false
        resting?.cancel()
        resting = nil
        reconcile()
        refreshIfDue()
    }

    func stream(for videoId: String) -> ResolvedStream? {
        guard let song = index.songs[videoId] else { return nil }
        var stream = song.stream
        stream.url = audio.file(for: song.key)
        return stream
    }

    /// Downloaded songs' files are the only local URLs the player may open.
    func holds(_ url: URL) -> Bool {
        url.isFileURL && url == audio.file(for: url.lastPathComponent)
    }

    /// Must finish before the player restores its song, which may be downloaded.
    func load() async {
        if let saved = await Self.read(store, audio) {
            index = saved
            // Clears files left by downloads cut short. Only after a good read, as an unreadable
            // index's songs are still on the phone.
            let (audio, keys, artwork) = (audio, Set(index.songs.values.map(\.key)), keptArtwork)
            Task {
                await audio.removeAll(except: keys)
                await ImagePipeline.shared.keepOnly(artwork)
            }
        }
        watchNetwork()
    }

    func settingsChanged(from old: Settings, to new: Settings) {
        if old.downloadOnWiFiOnly != new.downloadOnWiFiOnly { networkChanged() }
        if old.smartDownloads != new.smartDownloads || old.smartDownloadCount != new.smartDownloadCount {
            index.smartRefreshed = nil
            if !new.smartDownloads { index.smart = [] }
            changed()
            refreshIfDue()
        }
    }

    // MARK: Bringing the files in line

    func changed() {
        reconcile(saving: true)
    }

    /// Cancels and deletes what is no longer wanted, then starts downloads up to the limit.
    func reconcile(saving: Bool = false) {
        for (id, download) in active where !wantedIDs.contains(id) {
            download.task.cancel()
            active[id] = nil
            progress[id] = nil
        }
        let unwanted = index.songs.values.filter { !wantedIDs.contains($0.track.id) }
        if !unwanted.isEmpty {
            index.songs = index.songs.filter { wantedIDs.contains($0.key) }
            outOfRoom = false
            let (audio, keys, artwork) = (audio, unwanted.map(\.key), keptArtwork)
            Task {
                await audio.remove(keys)
                await ImagePipeline.shared.keepOnly(artwork)
            }
        }
        if saving || !unwanted.isEmpty { saveNow() }
        guard canDownload, !held, !outOfRoom, resting == nil else { return }
        for track in wanted {
            guard active.count < Self.simultaneous else { break }
            if index.songs[track.id] == nil, active[track.id] == nil, !failed.contains(track.id) { start(track) }
        }
    }

    /// Wanted songs' artwork, downloaded or not yet, and collections' covers.
    var keptArtwork: Set<String> {
        Set(wanted.compactMap(\.thumbnail) + index.collections.compactMap(\.thumbnail))
    }

    private func start(_ track: Track) {
        serial += 1
        let serial = serial
        progress[track.id] = 0
        let (music, chooser, audio, quality) = (music, chooser, audio, settings.value.downloadQuality)
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.progressed(track.id, serial, fraction) }
        }
        let task = Task { [weak self] in
            let result = await Result { () async throws -> ResolvedStream in
                // Alongside the song rather than after it, so the slot frees sooner.
                let artwork = Task { if let art = track.thumbnail { await ImagePipeline.shared.keep(art) } }
                defer { artwork.cancel() }
                let signedIn = await music.isSignedIn
                var stream = try await chooser.resolve(
                    videoId: track.id, wantPremium: signedIn && quality == .high, signedIn: signedIn, quality: quality,
                    counting: false
                )
                let item = try PlayerController.audioItem(
                    id: track.id, videoId: track.id, stream: stream, chooser: chooser, quality: quality, signedIn: signedIn,
                    local: false
                )
                try await audio.download(item, progress: report)
                await artwork.value
                // Saved without the signed URL or the client's headers, which the file never needs.
                stream.url = audio.file(for: item.cacheKey)
                stream.headers = [:]
                return stream
            }
            self?.finished(track, serial, result)
        }
        active[track.id] = (serial, task)
    }

    private func progressed(_ id: String, _ serial: Int, _ fraction: Double) {
        guard active[id]?.serial == serial else { return }
        progress[id] = fraction
    }

    private func finished(_ track: Track, _ serial: Int, _ result: Result<ResolvedStream, any Error>) {
        guard active[track.id]?.serial == serial else { return }
        active[track.id] = nil
        progress[track.id] = nil
        switch result {
        case .success(let stream):
            index.songs[track.id] = DownloadedSong(track: track, stream: stream, added: .now)
            if !indexSaving.isPending { indexSaving.schedule { [weak self] in self?.saveNow() } }
        case .failure(AudioFailure.storage):
            if !outOfRoom { toasts.yield("There's no room to download more songs. Free some space and try again.") }
            outOfRoom = true
        case .failure(is CancellationError):
            break
        case .failure(let error) where Self.isNetwork(error):
            // Not the song's fault, so it isn't marked failed; everything waits for the network.
            rest()
        case .failure(let error):
            let reason = (error as? AudioFailure)?.message ?? sentence(for: error)
            Logger.playback.info("\(track.id, privacy: .public): download failed: \(reason, privacy: .public)")
            failed.insert(track.id)
        }
        reconcile()
        // A song missing from the index has its file deleted at the next launch.
        if active.isEmpty { saveIfPending() }
    }

    func saveNow() {
        indexSaving.cancel()
        store.save(index, to: .downloads)
    }

    /// As downloads stop and the app leaves the screen.
    func saveIfPending() {
        if indexSaving.isPending { saveNow() }
    }

    private static func isNetwork(_ error: any Error) -> Bool {
        error is URLError || (error as? YTMError)?.kind == .network || [.download, .dropped].contains(error as? AudioFailure)
    }

    // MARK: The network

    var canDownload: Bool {
        online == true && !(metered && settings.value.downloadOnWiFiOnly)
    }

    private func rest() {
        guard resting == nil else { return }
        resting = Task { [weak self] in
            try? await Task.sleep(for: Self.retryAfter)
            guard let self, !Task.isCancelled else { return }
            resting = nil
            reconcile()
        }
    }

    private func watchNetwork() {
        let (paths, sink) = AsyncStream.makeStream(of: (online: Bool, metered: Bool).self, bufferingPolicy: .bufferingNewest(1))
        monitor.pathUpdateHandler = { sink.yield((online: $0.status == .satisfied, metered: $0.isExpensive)) }
        monitor.start(queue: DispatchQueue(label: "Lily.Downloads.network", qos: .utility))
        watching = Task { [weak self] in
            for await path in paths {
                self?.follow(online: path.online, metered: path.metered)
            }
        }
    }

    private func follow(online: Bool, metered: Bool) {
        let could = canDownload
        if self.online != online { self.online = online }
        if self.metered != metered { self.metered = metered }
        if canDownload != could { networkChanged() }
    }

    /// Stops downloads and the refresh on a network they may not use; on one they may, resumes and
    /// retries failed songs.
    private func networkChanged() {
        guard canDownload else {
            for download in active.values { download.task.cancel() }
            active.removeAll()
            progress.removeAll()
            refreshing?.cancel()
            refreshing = nil
            return
        }
        resume()
    }

    func announce(_ title: String) {
        let message = if canDownload {
            "Downloading “\(title)”"
        } else if online == true {
            "“\(title)” will download over Wi-Fi"
        } else {
            "“\(title)” will download once you're online"
        }
        toasts.yield(message)
    }

    /// Off the main actor, as the index may be large. The folder is kept out of backups, as the songs
    /// can be downloaded again; songs whose files are gone, as after a restore, are dropped to do so.
    @concurrent
    private static func read(_ store: FileStore, _ audio: AudioDownloader) async -> DownloadIndex? {
        var folder = store.downloads
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        guard var index = store.load(DownloadIndex.self, from: .downloads) else { return nil }
        index.songs = index.songs.filter { FileManager.default.fileExists(atPath: audio.file(for: $0.value.key).path(percentEncoded: false)) }
        return index
    }
}
