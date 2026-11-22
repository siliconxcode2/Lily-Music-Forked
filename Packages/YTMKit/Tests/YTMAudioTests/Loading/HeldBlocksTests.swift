import Testing
@testable import YTMAudio

struct HeldBlocksTests {
    private let megabyte = HeldBlocks.length

    private func fill(_ held: inout HeldBlocks, _ block: Int64) {
        let length = min(held.total - block * megabyte, megabyte)
        let have = held.held(Int(block))
        held.put(at: block * megabyte + have, count: length - have)
    }

    @Test func fetchesASeekFirstThenFillsTheGaps() {
        var held = HeldBlocks(total: 5 * megabyte + 100)
        held.put(at: 0, count: 64 << 10)
        #expect(held.nextRange(readingAt: 0) == 64 << 10, "on from the head")
        let seek = 3 * megabyte + 10
        #expect(held.nextRange(readingAt: seek) == 3 * megabyte, "the seek's block first")
        held.put(at: 3 * megabyte, count: 1_000)
        #expect(held.nextRange(readingAt: seek) == 3 * megabyte + 1_000, "then the rest of it")
        fill(&held, 3)
        fill(&held, 4)
        #expect(held.nextRange(readingAt: seek) == 5 * megabyte, "on to the end")
        fill(&held, 5)
        #expect(held.nextRange(readingAt: seek) == 64 << 10, "then the gap before")
        #expect(held.runEnd(from: seek) == held.total)
        #expect(held.runEnd(from: megabyte) == megabyte, "nothing held there")
        #expect(held.runEnd(from: 0) == 64 << 10, "the bytes from the start stop at the gap")
        for block in 0..<3 {
            fill(&held, Int64(block))
        }
        #expect(held.nextRange(readingAt: seek) == nil)
        #expect(held.runEnd(from: 0) == held.total, "all of it")
    }

    @Test func aStreamOfUnknownLengthRunsOnAcrossBlocks() {
        var held = HeldBlocks(total: 0)
        held.put(at: 0, count: megabyte + 5)
        #expect(held.held(1) == 5)
        #expect(held.nextRange(readingAt: 3 * megabyte) == megabyte + 5, "only ever on from the start")
    }
}
