import Foundation

/// When the sleep timer pauses: at a time, or as the song playing ends.
enum SleepTimer: Equatable {
    case at(Date)
    case endOfSong
}

extension AppModel {
    /// The lengths offered, in minutes, as Apple Music's are.
    static let sleepLengths = [15, 30, 45, 60]

    /// Replaces any timer running; nil turns it off.
    func setSleepTimer(_ timer: SleepTimer?) {
        sleepTask?.cancel()
        sleepTimer = timer
        guard let timer else { return }
        sleepTask = Task { [weak self] in
            switch timer {
            case .at(let end):
                try? await Task.sleep(for: .seconds(max(end.timeIntervalSinceNow, 0)))
            case .endOfSong:
                // Looked at twice a second, pausing within the song's last moments.
                while !Task.isCancelled {
                    guard let player = self?.player else { return }
                    if player.duration > 0, player.duration - player.currentTime < 0.6 { break }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            guard !Task.isCancelled, let self else { return }
            if player.isPlaying { player.togglePlayPause() }
            sleepTimer = nil
            showToast("Sleep timer ended")
        }
    }
}
