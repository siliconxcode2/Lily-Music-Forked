public enum AudioFailure: Error, Equatable, Sendable {
    /// The network failed after every retry.
    case download
    /// The connection stopped answering and stayed gone a minute.
    case dropped
    /// The server kept refusing the stream, even at a fresh URL.
    case refused
    /// The file is not Opus in WebM or AAC in MP4, or has more than two channels.
    case unsupported
    /// The file broke off or its container makes no sense.
    case damaged
    /// The audio cache could not be written.
    case storage
    case output
    case silent

    public var message: String {
        switch self {
        case .download: "The song couldn't be downloaded. Check your connection and try again."
        case .dropped: "Lost the connection."
        case .refused: "YouTube refused to send this song."
        case .unsupported: "This song's audio format isn't supported."
        case .damaged: "This song's audio is damaged."
        case .storage: "There's no room to store this song. Free some space and try again."
        case .output: "The audio output couldn't start."
        case .silent: "The song ended before it played."
        }
    }
}
