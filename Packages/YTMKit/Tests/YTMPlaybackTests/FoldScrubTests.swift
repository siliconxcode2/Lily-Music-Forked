import Foundation
import Testing
@testable import YTMPlayback

@Suite struct FoldScrubTests {
    /// Feeds readings a tenth of a second apart from `start`, as the hinge
    /// reports a turn, then lets it rest; returns every seek.
    private func seeks(_ scrub: inout FoldScrub, _ angles: [Double?], from start: TimeInterval) -> [Double] {
        var seeks: [Double] = []
        for (index, angle) in angles.enumerated() {
            let time = start + Double(index) / 10
            scrub.hinge(angle: angle, at: time)
            if let seek = scrub.settle(at: time + 0.05) { seeks.append(seek) }
        }
        if let seek = scrub.settle(at: start + Double(angles.count) / 10 + 1) { seeks.append(seek) }
        return seeks
    }

    /// Rested at 100° for a second and a half, so it is armed.
    private func armed() -> FoldScrub {
        var scrub = FoldScrub()
        scrub.hinge(angle: 100, at: 0)
        scrub.hinge(angle: 101, at: 1.5)
        return scrub
    }

    @Test func openingOrFoldingFromRestSeeksOnceItRestsAgain() {
        var scrub = armed()
        scrub.hinge(angle: 116, at: 2)
        #expect(scrub.settle(at: 2.1) == nil, "still turning")
        scrub.hinge(angle: 131, at: 2.1)
        #expect(scrub.settle(at: 2.6) == 20)
        #expect(scrub.settle(at: 3) == nil, "taken once")
        scrub.hinge(angle: 115, at: 4)
        #expect(scrub.settle(at: 4.5) == -10, "from where it rested, 131°")
    }

    @Test func aWobbleAfterASeekDoesNotSeekAgain() {
        var scrub = armed()
        #expect(seeks(&scrub, [108, 116, 124, 129], from: 2) == [10])
        #expect(seeks(&scrub, [131, 127, 130], from: 4).isEmpty)
    }

    @Test func aHeldPhoneThatStillReportsSeeksOnTime() {
        var scrub = armed()
        scrub.hinge(angle: 116, at: 2)
        scrub.hinge(angle: 130, at: 2.1)
        for (index, jitter) in [129.6, 130.2, 129.8, 130.1].enumerated() {
            let turned = scrub.hinge(angle: jitter, at: 2.2 + Double(index) / 10)
            #expect(!turned, "a wobble doesn't put the seek off")
        }
        #expect(scrub.settle(at: 2.55) == 20)
    }

    @Test func aSlowStartToAFoldNeverSeeks() {
        var scrub = FoldScrub()
        for (angle, time) in [(175.0, 0.0), (174, 0.5), (172.5, 1.0), (171, 1.2)] {
            scrub.hinge(angle: angle, at: time)
        }
        let fold = stride(from: 165.0, through: 100, by: -6).map { Optional($0) }
        #expect(seeks(&scrub, fold, from: 1.3).isEmpty, "armed by the slow start, but too far to be a scrub")
        #expect(seeks(&scrub, [112, 121], from: 4) == [10], "and armed where it came to rest")
    }

    @Test func foldingIntoThePoseNeverSeeks() {
        var scrub = FoldScrub()
        let fold = stride(from: 179.0, through: 95, by: -6).map { Optional($0) }
        #expect(seeks(&scrub, fold, from: 0).isEmpty)
    }

    @Test func aWobbleNeverSeeks() {
        var scrub = armed()
        #expect(seeks(&scrub, [102, 98, 103, 99, 101, 97, 100], from: 2).isEmpty)
    }

    @Test func foldingShutOrOpeningFlatNeverSeeks() {
        var shut = armed()
        #expect(seeks(&shut, [85, 60, 35, 10, nil], from: 2).isEmpty)
        var flat = armed()
        #expect(seeks(&flat, [120, 150, 175, nil], from: 2).isEmpty)
        #expect(seeks(&flat, [120, 140], from: 3).isEmpty, "opened flat, it must rest again before it arms")
    }
}
