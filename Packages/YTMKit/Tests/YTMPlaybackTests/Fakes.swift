import Foundation
import Synchronization
import YTMAudio
@testable import YTMCore
@testable import YTMPlayback

func song(_ id: String, album: String? = nil, number: Int? = nil, seconds: Int = 200, video: Bool = false) -> Track {
    Track(
        id: id, title: "Song \(id)", artists: [ArtistRef(id: "UC\(id)", name: "Artist")],
        album: album.map { AlbumRef(id: $0, name: "Album \($0)") }, duration: seconds, trackNumber: number, isVideo: video
    )
}

func songs(_ ids: String...) -> [Track] {
    ids.map { song($0) }
}

final class FakeMusic: MusicService {
    struct State {
        var signedIn = false
        var radios: [String: [Track]] = [:]
        /// The radio of any song without one of its own.
        var anyRadio: [Track] = []
        var failing: Set<String> = []
        /// Premium answers by video ID; songs missing have no Premium formats.
        var premium: [String: Bool] = [:]
        var premiumFails = false
        /// The Premium path's player script can't be had.
        var playerUnprepared = false
        var lyrics: [String: Lyrics] = [:]
        var lyricsFail = false
        /// Playlists and albums as `page` and `loadStep` serve them, a batch at a time.
        var playlistBatches: [String: [[Track]]] = [:]
        /// Batch tokens, as `PL#1`, that fail as YouTube's do: the page ends there, not whole.
        var failingBatches: Set<String> = []
        var ratings: [String: Rating] = [:]
        /// Where a play reported goes on to send its watch time.
        var watchTime: WatchTime?
        /// Streams, pages and cards' tracks held back until `release`, as a slow network.
        var held: Set<String> = []
        var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
        var calls: [String] = []
    }

    let state = Mutex(State())

    func set(_ change: @Sendable (inout State) -> Void) {
        state.withLock { change(&$0) }
    }

    var calls: [String] { state.withLock(\.calls) }

    /// Lets what is held for `videoId`, or a card's ID, through for good.
    func release(_ videoId: String) {
        let waiting = state.withLock { state in
            state.held.remove(videoId)
            return state.waiting.removeValue(forKey: videoId) ?? []
        }
        for continuation in waiting { continuation.resume() }
    }

    private func log(_ call: String) {
        state.withLock { $0.calls.append(call) }
    }

    var isSignedIn: Bool {
        get async { state.withLock(\.signedIn) }
    }

    static func stream(_ videoId: String, premium: Bool = false) -> ResolvedStream {
        var stream = ResolvedStream(
            url: URL(string: "https://rr1.googlevideo.com/videoplayback?id=\(videoId)") ?? URL(filePath: "/"),
            headers: [:], itag: premium ? 774 : 251, codec: .opus, contentLength: 1000, bitrate: 160_000,
            duration: 200, loudnessDb: 3, isPremium: premium
        )
        stream.client = premium ? nil : "VISIONOS"
        return stream
    }

    private func waitWhileHeld(_ id: String) async {
        guard state.withLock({ $0.held.contains(id) }) else { return }
        await withCheckedContinuation { continuation in
            let wait = state.withLock { state in
                guard state.held.contains(id) else { return false }
                state.waiting[id, default: []].append(continuation)
                return true
            }
            if !wait { continuation.resume() }
        }
    }

    func stream(videoId: String, quality: AudioQuality, itag: Int?) async throws -> ResolvedStream {
        log(itag.map { "stream \(videoId) \($0)" } ?? "stream \(videoId)")
        await waitWhileHeld(videoId)
        if state.withLock({ $0.failing.contains(videoId) }) { throw YTMError(.unplayable, "No audio.") }
        return Self.stream(videoId)
    }

    func cutOffStreams(of client: String) {
        log("cut off \(client)")
    }

    func premiumStream(videoId: String, anyFormat: Bool, maxKbps: Int?) async throws -> PremiumOutcome {
        log("premium \(videoId)")
        let (fails, unprepared, has) = state.withLock { ($0.premiumFails, $0.playerUnprepared, $0.premium[videoId]) }
        if unprepared { throw YTMError.playerUnprepared }
        if fails { throw YTMError(.network, "Premium failed.") }
        switch has {
        case true?: return .stream(Self.stream(videoId, premium: true))
        case false?, nil: return anyFormat ? .stream(Self.stream(videoId)) : .noPremiumFormats
        }
    }

    func preparePremium() async {
        log("prepare")
    }

    func suspectPremiumPlayer() async {
        log("suspect")
    }

    func radio(videoId: String) async throws -> [Track] {
        log("radio \(videoId)")
        await waitWhileHeld("radio \(videoId)")
        return state.withLock { $0.radios[videoId] ?? $0.anyRadio }
    }

    func radio(playlistId: String) async throws -> [Track] {
        log("radio \(playlistId)")
        return state.withLock { $0.radios[playlistId] } ?? []
    }

    func tracks(of card: Card) async throws -> [Track] {
        log("tracks \(card.id)")
        await waitWhileHeld(card.id)
        return state.withLock { $0.radios[card.id] } ?? []
    }

    func playlistTracks(_ playlistId: String) async throws -> [Track] {
        log("playlist \(playlistId)")
        return state.withLock { $0.radios[playlistId] } ?? []
    }

    func wholePlaylistTracks(_ playlistId: String) async throws -> [Track] {
        try await playlistTracks(playlistId)
    }

    func page(_ route: Route) async throws -> Page {
        let id: String
        switch route {
        case .playlist(let playlist), .album(let playlist): id = playlist
        default: throw YTMError(.notFound, "No such page.")
        }
        log("page \(id)")
        await waitWhileHeld(id)
        let batches = state.withLock { $0.playlistBatches[id] } ?? []
        return Page(
            header: PageHeader(title: id, playlistId: id),
            sections: [.tracks(TrackSection(title: "", tracks: batches.first ?? [], mode: .section))],
            more: batches.count > 1 ? .tracks(token: "\(id)#1") : nil
        )
    }

    func loadStep(_ page: Page) async throws -> (page: Page, whole: Bool) {
        guard case .tracks(let token, _, _)? = page.more, let id = page.header?.playlistId,
              let step = token.split(separator: "#").last.flatMap({ Int($0) }),
              case .tracks(var section)? = page.sections.first else { return (page, true) }
        log("more \(token)")
        var page = page
        if state.withLock({ $0.failingBatches.contains(token) }) {
            page.more = nil
            return (page, false)
        }
        let batches = state.withLock { $0.playlistBatches[id] } ?? []
        section.tracks += batches.indices.contains(step) ? batches[step] : []
        page.sections[0] = .tracks(section)
        page.more = step + 1 < batches.count ? .tracks(token: "\(id)#\(step + 1)") : nil
        return (page, true)
    }

    func songVersion(of video: Track) async throws -> Track? {
        log("version \(video.id)")
        return nil
    }

    func lyrics(videoId: String) async throws -> Lyrics? {
        log("lyrics \(videoId)")
        if state.withLock(\.lyricsFail) { throw YTMError(.network, "No connection.") }
        return state.withLock { $0.lyrics[videoId] }
    }

    func rating(videoId: String) async throws -> Rating {
        state.withLock { $0.ratings[videoId] } ?? .none
    }

    func rate(videoId: String, _ rating: Rating) async throws {
        log("rate \(videoId) \(rating.rawValue)")
    }

    func createPlaylist(title: String, videoIds: [String]) async throws -> String {
        log("create \(videoIds.count)")
        return "PL1"
    }

    func reportPlay(videoId: String) async throws -> WatchTime? {
        log("report \(videoId)")
        return state.withLock(\.watchTime)
    }

    func reportWatchTime(_ ping: WatchTime, _ watched: Watched) async throws {
        log("watchtime \(ping.url(for: watched).query(percentEncoded: true) ?? "")")
    }
}

@MainActor final class FakeAudio: AudioOutput {
    let events: AsyncStream<AudioEvent>
    var currentTime = 0.0
    var bufferedFraction = 0.0
    var equaliser: (enabled: Bool, gains: [Float]) = (false, [])
    var normalise: Float? = 1
    var crossfeed = false
    var mono = false
    var balance: Float = 0
    var pauseOnUnplug = true
    var isMuted = false
    var crossfadeSeconds = 6.0
    var speed = 1.0
    private(set) var played: [(item: AudioItem, from: Double, paused: Bool)] = []
    private(set) var next: AudioItem?
    private(set) var warmed: [AudioItem] = []
    private(set) var nextCrossfades = false
    private(set) var seeks: [Double] = []
    private(set) var log: [String] = []

    init() {
        events = AsyncStream { _ in }
    }

    func play(_ item: AudioItem, from seconds: Double, paused: Bool) {
        played.append((item, seconds, paused))
        currentTime = seconds
        next = nil
        log.append("play \(item.id)")
    }

    func setNext(_ item: AudioItem?, crossfade: Bool) {
        next = item
        nextCrossfades = crossfade
        log.append("next \(item?.id ?? "nil")")
    }

    func warm(_ item: AudioItem) {
        warmed.append(item)
    }

    func pause() { log.append("pause") }
    func resume() { log.append("resume") }

    func stop(keepingOutput: Bool) {
        next = nil
        bufferedFraction = 0
        log.append("stop")
    }

    func seek(to seconds: Double) {
        seeks.append(seconds)
        currentTime = seconds
    }

    func rebuild() {
        next = nil
        log.append("rebuild")
    }
}

actor FakeLastFM: Scrobbling {
    nonisolated let accessRevoked = AsyncStream<Void> { _ in }
    private(set) var nowPlaying: [String] = []
    private(set) var scrobbled: [String] = []

    func nowPlaying(_ track: Track) async {
        nowPlaying.append(track.id)
    }

    func scrobble(_ track: Track, startedAt: Date) async {
        scrobbled.append(track.id)
    }
}
