import Foundation
import Testing
@testable import YTMAudio

@MainActor
struct AudioPlayerTests {
    private func player(serving files: [String: Data]) -> AudioPlayer {
        let cache = AudioCache.Location(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), limit: 1 << 26)
        return AudioPlayer(output: .offline(sampleRate: Fixtures.rate), source: MemoryByteSource(files: files), cache: cache)
    }

    @Test func dropsTheEventsOfWhatPlayReplaced() async throws {
        let file = try Fixtures.opusWebM(Fixtures.signal(frames: 24_000))
        let player = player(serving: ["a": file, "b": file])
        player.play(try .fixture("a", length: file.count))
        player.play(try .fixture("b", length: file.count))
        var events = player.events.makeAsyncIterator()
        var seen: [AudioEvent] = []
        while seen.count < 3, let event = await events.next() {
            seen.append(event)
        }
        #expect(seen == [.buffering(true), .started(id: "b"), .buffering(false)])
        #expect(player.isPlaying)
        player.pause()
        #expect(!player.isPlaying)
        player.stop()
        player.resume()
        #expect(!player.isPlaying, "nothing to resume after a stop")
    }

    @Test func mutesWithNothingPlaying() {
        let player = player(serving: [:])
        player.isMuted = true
        player.isMuted = false
        #expect(!player.isMuted)
        #expect(player.currentTime == 0 && player.duration == nil)
    }
}
