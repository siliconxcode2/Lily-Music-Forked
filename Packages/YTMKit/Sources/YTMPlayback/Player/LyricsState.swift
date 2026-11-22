import YTMCore

/// Lyrics load only while `PlayerController.showsLyrics` is set.
public enum LyricsState: Equatable, Sendable {
    /// Not asked for yet, or nothing is playing.
    case idle
    case loading
    case unavailable
    case loaded(Lyrics)
    /// The sentence to show, such as "Couldn't load lyrics: You're offline."
    case failed(String)

    public var message: String? {
        switch self {
        case .idle: "Play something to see its lyrics."
        case .unavailable: "Lyrics aren't available for this song."
        case .failed(let message): message
        case .loading, .loaded: nil
        }
    }
}
