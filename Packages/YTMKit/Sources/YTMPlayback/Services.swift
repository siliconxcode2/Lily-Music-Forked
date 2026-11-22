import Foundation
import YTMAudio
import YTMCore

// The seams the player talks through, so its logic can be tested without
// YouTube or a sound device.

protocol MusicService: Sendable {
    var isSignedIn: Bool { get async }
    func stream(videoId: String, quality: AudioQuality, itag: Int?) async throws -> ResolvedStream
    func cutOffStreams(of client: String)
    func premiumStream(videoId: String, anyFormat: Bool, maxKbps: Int?) async throws -> PremiumOutcome
    func preparePremium() async
    func suspectPremiumPlayer() async
    func radio(videoId: String) async throws -> [Track]
    func radio(playlistId: String) async throws -> [Track]
    func tracks(of card: Card) async throws -> [Track]
    func playlistTracks(_ playlistId: String) async throws -> [Track]
    func wholePlaylistTracks(_ playlistId: String) async throws -> [Track]
    func page(_ route: Route) async throws -> Page
    func loadStep(_ page: Page) async throws -> (page: Page, whole: Bool)
    func songVersion(of video: Track) async throws -> Track?
    func lyrics(videoId: String) async throws -> Lyrics?
    func rating(videoId: String) async throws -> Rating
    func rate(videoId: String, _ rating: Rating) async throws
    func createPlaylist(title: String, videoIds: [String]) async throws -> String
    func reportPlay(videoId: String) async throws -> WatchTime?
    func reportWatchTime(_ ping: WatchTime, _ watched: Watched) async throws
}

extension YTMusic: MusicService {
    var isSignedIn: Bool {
        get async { await auth.isSignedIn }
    }
}

@MainActor protocol AudioOutput: AnyObject {
    var events: AsyncStream<AudioEvent> { get }
    var currentTime: Double { get }
    var bufferedFraction: Double { get }
    var equaliser: (enabled: Bool, gains: [Float]) { get set }
    var normalise: Float? { get set }
    var crossfeed: Bool { get set }
    var mono: Bool { get set }
    var balance: Float { get set }
    var pauseOnUnplug: Bool { get set }
    var isMuted: Bool { get set }
    var crossfadeSeconds: Double { get set }
    var speed: Double { get set }
    func play(_ item: AudioItem, from seconds: Double, paused: Bool)
    func setNext(_ item: AudioItem?, crossfade: Bool)
    func warm(_ item: AudioItem)
    func pause()
    func resume()
    func stop(keepingOutput: Bool)
    func seek(to seconds: Double)
    func rebuild()
}

extension AudioPlayer: AudioOutput {}

protocol Scrobbling: Sendable {
    /// Yields when the account stops allowing access.
    var accessRevoked: AsyncStream<Void> { get }
    func nowPlaying(_ track: Track) async
    func scrobble(_ track: Track, startedAt: Date) async
}

extension LastFM: Scrobbling {}
