import Testing
@testable import YTMPlayback

/// `#expect` cannot take a bare mutating call, so those that return a flag are bound first.
struct QueueTests {
    private func queue(_ count: Int) -> Queue<Int> {
        var queue = Queue<Int>(seed: 42)
        queue.set(items: 0..<count, start: 0, shuffle: false)
        return queue
    }

    private func items(_ queue: Queue<Int>) -> [Int] { Array(queue.items) }

    /// `to` is the final index, turned into SwiftUI's `onMove` offset.
    private func move(_ queue: inout Queue<Int>, _ from: Int, to: Int) -> Bool {
        queue.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
    }

    @Test func advancesAndStopsAtEnd() {
        var q = queue(3)
        #expect(q.advance(user: false, repeat: .off) == 1)
        #expect(q.advance(user: false, repeat: .off) == 2)
        #expect(q.advance(user: false, repeat: .off) == nil)
        #expect(q.current == 2)
    }

    @Test func repeatModes() {
        var q = queue(2)
        q.advance(user: false, repeat: .all)
        #expect(q.advance(user: false, repeat: .all) == 0)
        #expect(q.advance(user: false, repeat: .one) == 0)
        #expect(q.advance(user: true, repeat: .one) == 1, "skipping leaves repeat-one")
    }

    @Test func backWrapsOnlyWithRepeatAll() {
        var q = queue(3)
        #expect(q.back(repeat: .one) == 0)
        #expect(q.back(repeat: .all) == 2)
    }

    @Test func replacesInPlaceThroughShuffle() throws {
        var q = queue(10)
        q.jump(to: 2)
        q.setShuffle(true)
        let revision = q.revision
        let at = try #require(q.items.firstIndex(of: 7))
        #expect(q.replace(where: { $0 == 7 }, with: 70) == [at])
        #expect(q.revision == revision, "nothing moved")
        #expect(q.current == 2)
        #expect(q.replace(where: { $0 == 99 }, with: 0).isEmpty, "nothing to replace")

        q.setShuffle(false)
        #expect(items(q) == [0, 1, 2, 3, 4, 5, 6, 70, 8, 9])
    }

    @Test func shuffleKeepsCurrentAndRestoresOrder() throws {
        var q = queue(20)
        q.jump(to: 5)
        q.setShuffle(true)
        let shuffled = items(q)
        #expect(shuffled.prefix(6) == [0, 1, 2, 3, 4, 5])
        #expect(shuffled != Array(0..<20))
        #expect(shuffled.sorted() == Array(0..<20))

        q.advance(user: false, repeat: .off)
        let playing = try #require(q.current)
        q.setShuffle(false)
        #expect(items(q) == Array(0..<20))
        #expect(q.current == playing)
    }

    @Test func unshuffleKeepsTracksAddedWhileShuffledBehindTheirNeighbour() throws {
        var q = queue(5)
        q.setShuffle(true)
        q.append(contentsOf: [99])
        let after = items(q)[4]
        q.setShuffle(false)
        let order = items(q)
        #expect(order.count == 6)
        let at = try #require(order.firstIndex(of: 99))
        #expect(order[at - 1] == after, "still follows the track it was added after")

        q = queue(5)
        q.jump(to: 2)
        q.setShuffle(true)
        q.playNext(99)
        q.advance(user: false, repeat: .off)
        #expect(q.current == 99)
        q.setShuffle(false)
        #expect(items(q) == [0, 1, 2, 99, 3, 4])
        #expect(q.current == 99, "the playing track stays where it is")
        #expect(q.advance(user: false, repeat: .off) == 3)
    }

    @Test func recommendationsGoAfterTheCurrentTrackOnly() {
        var q = queue(4)
        q.jump(to: 1)
        let revision = q.revision
        q.insertRecommended(50, at: 1)
        q.insertRecommended(50, at: 0)
        #expect(items(q) == [0, 1, 2, 3], "never at or before the current")
        #expect(q.revision == revision)
        q.insertRecommended(50, at: 2)
        q.insertRecommended(51, at: 5)
        #expect(items(q) == [0, 1, 50, 2, 3, 51])
        #expect(q.current == 1)
        #expect(q.isRecommended(at: 2) && q.isRecommended(at: 5))
        #expect(!q.isRecommended(at: 1))
        #expect(q.recommendedIndices == [2, 5])
        #expect(q.revision != revision)
    }

    @Test func removingRecommendationsRestoresTheUsersOrder() {
        var q = queue(6)
        q.jump(to: 1)
        q.setShuffle(true)
        let shuffled = items(q)
        q.insertRecommended(50, at: 2)
        q.insertRecommended(51, at: 5)
        q.advance(user: false, repeat: .off)
        q.advance(user: false, repeat: .off)
        #expect(q.current == shuffled[2])
        let revision = q.revision
        let removed = q.removeRecommended()
        #expect(removed)
        #expect(items(q) == shuffled, "the user's shuffled order is back")
        #expect(q.current == shuffled[2], "the index moved with the track")
        #expect(q.revision != revision)
        let removedAgain = q.removeRecommended()
        #expect(!removedAgain, "nothing left to remove")

        q.setShuffle(false)
        #expect(items(q) == [0, 1, 2, 3, 4, 5])
    }

    @Test func aPlayingRecommendationIsKept() {
        var q = queue(3)
        q.insertRecommended(50, at: 1)
        q.insertRecommended(51, at: 3)
        q.advance(user: false, repeat: .off)
        #expect(q.current == 50)
        let removed = q.removeRecommended()
        #expect(removed)
        #expect(items(q) == [0, 50, 1, 2])
        #expect(q.current == 50)
        #expect(q.isRecommended(at: 1), "still marked as one")
    }

    @Test func movesEntriesAndTheCurrentIndexFollows() {
        var q = queue(6)
        q.jump(to: 2)
        var revision = q.revision
        var moved = move(&q, 4, to: 1)
        #expect(moved, "a later entry to before the current")
        #expect(items(q) == [0, 4, 1, 2, 3, 5])
        #expect(q.current == 2)
        #expect(q.currentIndex == 3)
        #expect(q.revision != revision)

        moved = move(&q, 0, to: 5)
        #expect(moved, "an earlier entry to after the current")
        #expect(items(q) == [4, 1, 2, 3, 5, 0])
        #expect(q.currentIndex == 2)

        moved = move(&q, 2, to: 0)
        #expect(moved, "the current track itself")
        #expect(items(q) == [2, 4, 1, 3, 5, 0])
        #expect(q.currentIndex == 0)
        #expect(q.current == 2)

        revision = q.revision
        moved = move(&q, 1, to: 1) || move(&q, 1, to: 9)
        #expect(!moved)
        #expect(q.revision == revision, "nothing to move changes nothing")
    }

    @Test func movesSeveralEntriesAsSwiftUIDoes() {
        var q = queue(8)
        q.jump(to: 3)
        var moved = q.move(fromOffsets: [1, 3, 6], toOffset: 5)
        #expect(moved)
        #expect(items(q) == [0, 2, 4, 1, 3, 6, 5, 7])
        #expect(q.current == 3)
        #expect(q.currentIndex == 4)

        moved = q.move(fromOffsets: [6, 7], toOffset: 0)
        #expect(moved)
        #expect(items(q) == [5, 7, 0, 2, 4, 1, 3, 6])
        #expect(q.currentIndex == 6)

        let revision = q.revision
        moved = q.move(fromOffsets: [2, 3], toOffset: 4) || q.move(fromOffsets: [2, 3], toOffset: 2)
        #expect(!moved, "already there")
        moved = q.move(fromOffsets: [], toOffset: 0) || q.move(fromOffsets: [8], toOffset: 0)
            || q.move(fromOffsets: [0], toOffset: 9)
        #expect(!moved, "nothing to move, or out of range")
        #expect(q.revision == revision)
    }

    @Test func movingWhileShuffledRestoresTheOriginalOrder() throws {
        var q = queue(8)
        q.jump(to: 1)
        q.setShuffle(true)
        q.move(fromOffsets: [7], toOffset: 2)
        q.move(fromOffsets: [3], toOffset: 7)
        q.advance(user: false, repeat: .off)
        let playing = try #require(q.current)
        q.setShuffle(false)
        #expect(items(q) == Array(0..<8))
        #expect(q.current == playing)
    }

    @Test func removesManyButNeverTheCurrent() {
        var q = queue(7)
        q.jump(to: 3)
        #expect(q.removeMany([5, 0, 3, 1, 99, 5]) == [0, 1, 5])
        #expect(items(q) == [2, 3, 4, 6])
        #expect(q.current == 3)
        #expect(q.currentIndex == 1)
        let revision = q.revision
        #expect(q.removeMany([1]).isEmpty, "only the current: nothing")
        #expect(q.revision == revision)
    }

    @Test func playsASelectionNextInQueueOrder() {
        var q = queue(8)
        q.jump(to: 3)
        let moved = q.playNextMany([6, 1, 3, 7])
        #expect(moved)
        #expect(items(q) == [0, 2, 3, 1, 6, 7, 4, 5])
        #expect(q.current == 3)
        #expect(q.currentIndex == 2)
        #expect(q.peekNext(repeat: .off) == 1)

        let revision = q.revision
        let alreadyNext = q.playNextMany([3, 4, 5])
        #expect(!alreadyNext, "already next, in that order")
        let currentMoved = q.playNextMany([2])
        #expect(!currentMoved, "the current track never moves")
        let noneMoved = q.playNextMany([])
        #expect(!noneMoved)
        #expect(q.revision == revision)
    }

    @Test func playsASelectionNextThroughShuffle() {
        var q = queue(10)
        q.jump(to: 4)
        q.setShuffle(true)
        let shuffled = items(q)
        let moved = q.playNextMany([8, 9])
        #expect(moved)
        #expect(q.peekNext(repeat: .off) == shuffled[8])
        q.setShuffle(false)
        #expect(items(q) == Array(0..<10))
        #expect(q.current == 4)
    }

    @Test func marksRestoredRecommendations() {
        var q = queue(4)
        q.markRecommended([1, 3, 9])
        #expect(q.recommendedIndices == [1, 3])
        #expect(q.entries.filter(\.isRecommended).map(\.item) == [1, 3])
    }

    @Test func playNextAndRemove() throws {
        var q = queue(3)
        q.playNext(7)
        #expect(items(q) == [0, 7, 1, 2])
        q.jump(to: 2)
        #expect(q.removeMany([0]) == [0])
        #expect(q.current == 1)
        let current = try #require(q.currentIndex)
        #expect(q.removeMany([current]).isEmpty, "cannot remove the current track")
    }

    @Test func emptyQueueStartsWithFirstPush() {
        var q = Queue<Int>(seed: 1)
        #expect(q.advance(user: false, repeat: .off) == nil)
        q.append(contentsOf: [4])
        #expect(q.current == 4)
    }

    @Test func revisionTracksChangesToEntriesOnly() {
        var q = queue(3)
        var revision = q.revision
        q.advance(user: false, repeat: .off)
        q.jump(to: 0)
        q.back(repeat: .off)
        #expect(q.revision == revision, "moving through the queue changes nothing")
        q.append(contentsOf: [9])
        #expect(q.revision != revision)
        revision = q.revision
        q.setShuffle(true)
        #expect(q.revision != revision)
    }

    @Test func clearsUpcoming() {
        var q = queue(5)
        q.jump(to: 1)
        q.clearUpcoming()
        #expect(items(q) == [0, 1])
    }

    @Test func setClampsTheStartAndCanShuffle() {
        var q = Queue<Int>(seed: 7)
        q.set(items: 0..<6, start: 9, shuffle: true)
        #expect(q.currentIndex == 0 && q.current == 5, "the start leads, the rest shuffled after it")
        q.setShuffle(false)
        #expect(items(q) == Array(0..<6))
        #expect(q.currentIndex == 5)
        q.set(items: [], start: 0, shuffle: false)
        #expect(q.current == nil)
    }

    @Test func aShuffledStartPartWayThroughPlaysEveryTrack() {
        var q = Queue<Int>(seed: 42)
        q.set(items: 0..<20, start: 10, shuffle: true)
        var heard = [q.current]
        while let next = q.advance(user: false, repeat: .off) { heard.append(next) }
        #expect(heard.first == 10)
        #expect(heard.compactMap(\.self).sorted() == Array(0..<20))
        q.setShuffle(false)
        #expect(items(q) == Array(0..<20))
    }

    @Test func tracksAddedWhileShuffledMixInAndGoLastUnshuffled() {
        var q = queue(10)
        q.setShuffle(true)
        q.advance(user: false, repeat: .off)
        q.advance(user: false, repeat: .off)
        let played = Array(items(q)[..<3])
        q.extend(10..<20)
        let order = items(q)
        #expect(Array(order[..<3]) == played, "what has played stays put")
        #expect(order[3..<10].contains { $0 >= 10 }, "mixed in among those still to play")
        #expect(order.sorted() == Array(0..<20))
        q.setShuffle(false)
        #expect(items(q) == Array(0..<20))
    }

    @Test func tracksAddedWhileShuffledGoBehindOnePlayedNext() {
        var q = queue(10)
        q.setShuffle(true)
        q.playNext(99)
        q.extend(10..<400)
        #expect(q.peekNext(repeat: .off) == 99)
    }

    @Test func tracksAddedUnshuffledGoLast() {
        var q = queue(3)
        q.extend([7, 8])
        #expect(items(q) == [0, 1, 2, 7, 8])
    }

    /// A row stays the same row however the queue moves.
    @Test func entryIdsFollowTheirEntries() throws {
        var q = queue(6)
        q.jump(to: 1)
        // Items below 6 sit in one entry each, so each names its entry.
        func ids() -> [Int: Int] {
            Dictionary(uniqueKeysWithValues: q.entries.lazy.filter { $0.item < 6 }.map { ($0.item, $0.id) })
        }
        let before = ids()
        func kept() -> Bool { ids().allSatisfy { before[$0.key] == $0.value } }

        #expect(move(&q, 4, to: 0))
        #expect(kept())
        q.playNext(10)
        #expect(kept())
        let movedNext = q.playNextMany([5])
        #expect(movedNext && kept())
        let removed = q.removeMany([3])
        #expect(!removed.isEmpty && kept() && ids().count == 5)
        q.setShuffle(true)
        #expect(kept())
        q.setShuffle(false)
        #expect(kept())

        let current = try #require(q.currentIndex)
        q.insertRecommended(20, at: current + 1)
        q.insertRecommended(20, at: current + 1)
        q.append(contentsOf: [10, 30])
        #expect(Set(q.entries.map(\.id)).count == q.count, "the same item in several entries, each its own")
    }
}
