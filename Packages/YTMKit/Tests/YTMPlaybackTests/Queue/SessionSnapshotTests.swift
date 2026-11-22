import Foundation
import Testing
@testable import YTMCore
@testable import YTMPlayback

struct SessionSnapshotTests {
    @Test func keepsShortQueuesWholeAndLongOnesAroundTheTrack() {
        #expect(SessionSnapshot.window(count: 400, index: 350) == 0..<400)
        #expect(SessionSnapshot.window(count: 1000, index: 100) == 0..<500)
        #expect(SessionSnapshot.window(count: 1000, index: 600) == 350..<850)
        #expect(SessionSnapshot.window(count: 1000, index: 990) == 740..<1000)
    }

    @Test func savesTheWindowWithItsRecommendations() throws {
        var queue = Queue<Track>(seed: 1)
        queue.set(items: (0..<1000).map { song("\($0)") }, start: 600, shuffle: false)
        queue.insertRecommended(song("r1"), at: 601)
        queue.insertRecommended(song("r2"), at: 900)
        let snapshot = try #require(SessionSnapshot(queue, position: 12, duration: 200))
        #expect(snapshot.queue.count == 500)
        #expect(snapshot.queue[snapshot.index].id == "600")
        #expect(snapshot.recommended == [251], "r2 falls outside the window")
        #expect(SessionSnapshot(Queue<Track>(), position: 0, duration: 0) == nil, "nothing to save")
    }
}
