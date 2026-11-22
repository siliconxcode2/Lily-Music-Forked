import Foundation

struct PlaybackState {
    /// Bumped as each song starts, so results for an earlier one are dropped.
    var generation: UInt64 = 0
    /// The song's sound has started.
    var started = false
    /// The song was asked for and has not sounded yet.
    var loading = false
    /// Waiting on the network mid-song.
    var stalled = false
    var duration = 0.0
    var failures = 0
    /// When the song was asked for, to time the first sound.
    var requestedAt: ContinuousClock.Instant?
    var currentPremium = false
    /// A song whose Premium stream failed and plays the free one instead.
    var forceFree: String?
    /// Where a song is to start: restored from the last launch, sought to
    /// with nothing loaded or while opened again, or where a Premium retry or
    /// dropped connection left off. Kept until it sounds, so a load that fails
    /// starts there again.
    var resume: (id: String, position: Double)?
    /// The generation whose play is already recorded: a free-stream retry
    /// carrying on a song, so its start is not a second play.
    var playRecorded: UInt64?
    /// A radio is being fetched to carry on from the queue's end.
    var extending = false
    /// The engine's ID for the song, once it has it.
    var itemID: String?
    /// Where the song is while the engine has none of it: restored, loading
    /// or stopped.
    var heldPosition = 0.0
    /// A song whose connection dropped, and the tries at opening it again.
    var reopen: (id: String, tries: Int)?

    /// Counts a try at reopening `id`; once it has sounded, keeps where it got to and its play. Returns the tries.
    mutating func reopenTry(_ id: String, position: Double) -> Int {
        if started {
            resume = (id, position)
            playRecorded = generation
        }
        let tries = reopening(id) ? (reopen?.tries ?? 0) + 1 : 1
        reopen = (id, tries)
        return tries
    }

    func reopening(_ id: String) -> Bool {
        reopen?.id == id
    }
}
