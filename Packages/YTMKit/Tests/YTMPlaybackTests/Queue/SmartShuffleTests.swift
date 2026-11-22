import Foundation
import Testing
@testable import YTMCore
@testable import YTMPlayback

struct SmartShuffleTests {
    private func queue(_ count: Int) -> Queue<Track> {
        var queue = Queue<Track>(seed: 7)
        queue.set(items: (0..<count).map { song("\($0)") }, start: 0, shuffle: false)
        return queue
    }

    @Test func asksForABatchWhenThePoolIsDry() {
        var smart = SmartShuffle()
        var queue = queue(20)
        let seed = smart.topUp(&queue, recent: [])
        #expect(seed != nil)
        #expect(smart.fetching)
        let result14 = smart.topUp(&queue, recent: [])
        #expect(result14 == nil, "one batch at a time")
        #expect(queue.recommendedIndices.isEmpty)
    }

    @Test func placesOneRecommendationAfterEveryThreeOrFourOwnSongsAhead() {
        var smart = SmartShuffle()
        var queue = queue(20)
        _ = smart.topUp(&queue, recent: ["r0"])
        let fresh = smart.receive((0..<10).map { song("r\($0)") } + [song("5")], generation: smart.generation)
        #expect(fresh)
        _ = smart.topUp(&queue, recent: ["r0"])
        let marks = queue.recommendedIndices
        #expect(marks.count >= 2)
        var own = 0
        var runs: [Int] = []
        for index in 0..<queue.count {
            if queue.isRecommended(at: index) {
                runs.append(own)
                own = 0
            } else {
                own += 1
            }
        }
        #expect(runs.allSatisfy { (3...4).contains($0) }, "the playing song counts towards the first run")
        #expect(!queue.items.contains { $0.id == "r0" }, "recently played songs are not recommended")
        #expect(queue.items.filter { $0.id == "5" }.count == 1, "nor songs already in the queue")
        let lastOwn = queue.items.lastIndex { !$0.id.hasPrefix("r") } ?? 0
        #expect(marks.allSatisfy { $0 < lastOwn }, "never after the last of the user's own")
        let ownAhead = (0..<(marks.last ?? 0)).filter { !queue.isRecommended(at: $0) }.count - 1
        #expect(ownAhead <= SmartShuffle.lookahead)
    }

    @Test func dropsABatchAskedForAnEarlierQueue() {
        var smart = SmartShuffle()
        var queue = queue(20)
        _ = smart.topUp(&queue, recent: [])
        let asked = smart.generation
        smart.reset()
        let result15 = smart.receive([song("r")], generation: asked)
        #expect(!result15)
        #expect(!smart.fetching)
    }
}
