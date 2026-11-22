import AVFoundation
import Testing
@testable import YTMAudio

struct PlaybackClockTests {
    private let second = AVAudioTime.hostTime(forSeconds: 1)

    @Test func holdsUntilRunning() {
        let clock = PlaybackClock()
        clock.pin(12.5, since: nil)
        #expect(clock.position(at: mach_absolute_time() + second) == 12.5)
    }

    @Test func runsOnFromItsPinUpToTheSoundScheduled() {
        let clock = PlaybackClock()
        let now = mach_absolute_time()
        clock.pin(30, since: now, limit: 31.5)
        #expect(abs(clock.position(at: now + second) - 31) < 1e-6)
        #expect(clock.position(at: now + 3 * second) == 31.5, "a stall holds it at the end of the sound")
        #expect(clock.position(at: now - second) == 30)
    }

    @Test func runsOnAtTheSpeed() {
        let clock = PlaybackClock()
        let now = mach_absolute_time()
        clock.pin(30, since: now)
        clock.setSpeed(1.5, at: now + second)
        #expect(abs(clock.position(at: now + second) - 31) < 1e-6, "the speed counts from its change")
        #expect(abs(clock.position(at: now + 3 * second) - 34) < 1e-6)
        clock.pin(10, since: now)
        #expect(abs(clock.position(at: now + 2 * second) - 13) < 1e-6, "a pin keeps the speed")
    }

    @Test func keepsTheDurationAndDownload() {
        let clock = PlaybackClock()
        #expect(clock.duration == nil && clock.buffered == 0)
        clock.describe(duration: 213.04, buffered: 0.25)
        #expect(clock.duration == 213.04 && clock.buffered == 0.25)
    }
}
