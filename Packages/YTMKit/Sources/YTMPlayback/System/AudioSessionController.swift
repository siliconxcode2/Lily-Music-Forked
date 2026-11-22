import AVFoundation
import os

/// Unplugging the device playing pauses, unless Settings says to carry on; a device
/// plugged in plays on, and the engine follows the new output itself.
@MainActor final class AudioSessionController {
    #if os(iOS)
    private var isActive = false
    /// Playing when the system took the session away, so it resumes only then.
    private var resumeAfterInterruption = false
    private var observers: [NotificationCenter.ObservationToken] = []
    /// The media services reset and route changes have no typed messages, so they are observed by name.
    private var resetObserver: (any NSObjectProtocol)?
    private var routeObserver: (any NSObjectProtocol)?
    /// iOS 26 has no typed session messages either, so interruptions come by name there.
    private var interruptionObserver: (any NSObjectProtocol)?

    init(player: PlayerController) {
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter.default
        if #available(iOS 27, *) {
            observers = [
                center.addObserver(of: session, for: .didBecomeInactive) { [weak self, weak player] message in
                    guard let self else { return }
                    // However the system took the session, the next play must ask
                    // for it again; only an interruption pauses the player.
                    isActive = false
                    guard let player, case .systemInterruption = message.deactivationResult else { return }
                    interrupted(player)
                },
                center.addObserver(of: session, for: .resumptionRecommendation) { [weak self, weak player] message in
                    guard let self, let player else { return }
                    resume(player, recommended: message.recommendation == .shouldResume)
                },
            ]
        } else {
            interruptionObserver = center.addObserver(
                forName: AVAudioSession.interruptionNotification, object: session, queue: .main
            ) { [weak self, weak player] notification in
                let info = notification.userInfo
                let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                let options = AVAudioSession.InterruptionOptions(rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                guard let self, let player else { return }
                MainActor.assumeIsolated {
                    switch type {
                    case .began:
                        isActive = false
                        interrupted(player)
                    case .ended:
                        resume(player, recommended: options.contains(.shouldResume))
                    default:
                        break
                    }
                }
            }
        }
        resetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
        ) { [weak self, weak player] _ in
            guard let self, let player else { return }
            MainActor.assumeIsolated { self.servicesReset(player) }
        }
        routeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self, weak player] notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init)
            // Apple's reason for headphones unplugged and Bluetooth, AirPlay, CarPlay or USB going away.
            guard let self, let player, reason == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated {
                guard player.settings.value.pauseOnUnplug else { return }
                // A call ending after the headphones were pulled must not resume through the speaker.
                resumeAfterInterruption = false
                player.outputUnplugged()
            }
        }
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for observer in [resetObserver, routeObserver, interruptionObserver].compactMap(\.self) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Must run before the engine plays; a no-op once active, until the system takes the session away.
    func activate() {
        guard !isActive else { return }
        do {
            // The default route sharing, not long-form audio's, under which
            // headphone presses (AirPods squeezes) never reached the app.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            isActive = true
        } catch {
            Logger.playback.error("The audio session couldn't start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func interrupted(_ player: PlayerController) {
        resumeAfterInterruption = player.isPlaying
        if player.isPlaying { player.setPaused(true) }
    }

    /// The reset took the session with it, so the next `activate` sets it up again, as Apple asks.
    private func servicesReset(_ player: PlayerController) {
        isActive = false
        resumeAfterInterruption = false
        player.mediaServicesReset()
    }

    private func resume(_ player: PlayerController, recommended: Bool) {
        defer { resumeAfterInterruption = false }
        guard recommended, resumeAfterInterruption else { return }
        player.setPaused(false)
    }
    #else
    init(player _: PlayerController) {}

    func activate() {}
    #endif
}
