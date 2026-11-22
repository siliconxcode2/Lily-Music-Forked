import CoreGraphics
import Foundation
import MediaPlayer
import YTMCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor final class NowPlayingCenter {
    /// Seconds the system's reckoning of the position may drift, as through a
    /// stall, before it is told again.
    private static let allowedDrift = 1.0

    private let info = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    private var metadata: [String: Any] = [:]
    /// The song shown, so artwork arriving for an earlier one is dropped.
    private var trackID: String?
    private var artwork: Task<Void, Never>?
    private var published: (elapsed: Double, rate: Double, at: ContinuousClock.Instant)?
    /// The system runs the position on at this rate; times stay in the song's own.
    var speed = 1.0

    init(player: PlayerController) {
        commands.playCommand.addTarget(on: player) { $0.setPaused(false) }
        commands.pauseCommand.addTarget(on: player) { $0.setPaused(true) }
        commands.togglePlayPauseCommand.addTarget(on: player) { $0.togglePlayPause() }
        commands.nextTrackCommand.addTarget(on: player) { $0.next() }
        commands.previousTrackCommand.addTarget(on: player) { $0.previous() }
        commands.changePlaybackPositionCommand.addTarget(on: player, reading: { ($0 as? MPChangePlaybackPositionCommandEvent)?.positionTime }) {
            $0.seek(to: $1)
        }
        commands.likeCommand.localizedTitle = "Like"
        commands.likeCommand.addTarget(on: player) { $0.rate(.like) }
        setLike(isLiked: false, enabled: false)
    }

    func show(_ track: Track, duration: Double) {
        artwork?.cancel()
        trackID = track.id
        published = nil
        metadata = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistNames,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        metadata[MPMediaItemPropertyAlbumTitle] = track.album?.name
        setDuration(duration)
        guard let url = track.thumbnail else { return }
        if let image = ImagePipeline.shared.cachedImage(for: url, pixelEdge: ImagePipeline.playerEdge) {
            metadata[MPMediaItemPropertyArtwork] = Self.artwork(image)
            return
        }
        // The row's small copy, scaled up by the system, so the lock screen
        // has artwork while the large one loads.
        if let small = ImagePipeline.shared.cachedImage(for: url, pixelEdge: ImagePipeline.smallEdge) {
            metadata[MPMediaItemPropertyArtwork] = Self.artwork(small)
        }
        let id = track.id
        artwork = Task { [weak self] in
            guard let image = await ImagePipeline.shared.image(for: url, pixelEdge: ImagePipeline.playerEdge),
                  let self, trackID == id else { return }
            metadata[MPMediaItemPropertyArtwork] = Self.artwork(image)
            // A new dictionary restarts the system's reckoning from its
            // elapsed time, which must be brought up to now.
            if let published {
                let elapsed = reckoned(published)
                metadata[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(elapsed, 0)
                self.published = (elapsed, published.rate, .now)
            }
            info.nowPlayingInfo = metadata
        }
    }

    func setDuration(_ duration: Double) {
        metadata[MPMediaItemPropertyPlaybackDuration] = duration > 0 ? duration : nil
    }

    /// `playing` sets the play button; `advancing` (not loading or stalled) lets
    /// the system run the position on by itself.
    func setPlayback(playing: Bool, advancing: Bool, elapsed: Double) {
        guard trackID != nil else { return }
        let rate = advancing ? speed : 0
        metadata[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(elapsed, 0)
        metadata[MPNowPlayingInfoPropertyPlaybackRate] = rate
        published = (elapsed, rate, .now)
        info.nowPlayingInfo = metadata
        info.playbackState = playing ? .playing : .paused
    }

    /// Run each tick: tells the system the position again only when its reckoning has drifted.
    func keep(elapsed: Double, advancing: Bool) {
        guard let published else { return }
        if abs(reckoned(published) - elapsed) > Self.allowedDrift || (published.rate > 0) != advancing {
            setPlayback(playing: true, advancing: advancing, elapsed: elapsed)
        }
    }

    private func reckoned(_ published: (elapsed: Double, rate: Double, at: ContinuousClock.Instant)) -> Double {
        published.elapsed + (ContinuousClock.now - published.at).seconds * published.rate
    }

    func setLike(isLiked: Bool, enabled: Bool) {
        commands.likeCommand.isEnabled = enabled
        commands.likeCommand.isActive = isLiked
    }

    // Nonisolated: MediaPlayer asks for the image on its own queue, and a
    // closure made on the main actor would trap there.
    nonisolated private static func artwork(_ image: CGImage) -> MPMediaItemArtwork {
        let size = CGSize(width: image.width, height: image.height)
        #if canImport(UIKit)
        return MPMediaItemArtwork(boundsSize: size) { _ in UIImage(cgImage: image) }
        #else
        return MPMediaItemArtwork(boundsSize: size) { _ in NSImage(cgImage: image, size: size) }
        #endif
    }
}

private extension MPRemoteCommand {
    /// The system calls handlers from its own thread, so they hop to the main
    /// actor rather than assume it, with the event's values, not the event.
    func addTarget<Value: Sendable>(
        on player: PlayerController, reading read: @escaping @Sendable (MPRemoteCommandEvent) -> Value?,
        _ action: @escaping @MainActor @Sendable (PlayerController, Value) -> Void
    ) {
        addTarget { [weak player] event in
            guard let value = read(event) else { return .commandFailed }
            Task { @MainActor in
                guard let player else { return }
                action(player, value)
            }
            return .success
        }
    }

    func addTarget(on player: PlayerController, _ action: @escaping @MainActor @Sendable (PlayerController) -> Void) {
        addTarget(on: player, reading: { _ in () }) { player, _ in action(player) }
    }
}
