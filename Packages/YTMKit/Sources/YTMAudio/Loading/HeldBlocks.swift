/// Which bytes of a download are on disk, by 1 MB block, each filled from its start: the download follows the
/// reader, so a seek ahead is fetched next and the gaps after.
struct HeldBlocks {
    static let length = StreamLoader.rangeLength

    /// The file's length, or 0 until a download of unknown length ends.
    var total: Int64
    /// The bytes held from each block's start.
    private var held: [Int64] = []

    init(total: Int64) {
        self.total = total
    }

    func held(_ block: Int) -> Int64 {
        block < held.count ? held[block] : 0
    }

    /// The end of the bytes held unbroken from `position`, or `position` if its byte is missing.
    func runEnd(from position: Int64) -> Int64 {
        var block = Int(position / Self.length)
        while held(block) == Self.length {
            block += 1
        }
        return max(Int64(block) * Self.length + held(block), position)
    }

    /// Where the next range starts: in the block read from and on from it, then any gap from the start.
    /// Nil once every byte is held; with no length known, always on from the bytes held from the start.
    func nextRange(readingAt position: Int64) -> Int64? {
        guard total > 0 else { return runEnd(from: 0) }
        let count = Int((total + Self.length - 1) / Self.length)
        let from = min(Int(max(position, 0) / Self.length), count - 1)
        let missing = { (block: Int) in held(block) < min(total - Int64(block) * Self.length, Self.length) }
        let block = (from..<count).first(where: missing) ?? (0..<from).first(where: missing)
        return block.map { Int64($0) * Self.length + held($0) }
    }

    /// Counts `count` bytes at `offset`, which follows what its block holds.
    mutating func put(at offset: Int64, count: Int64) {
        var at = offset
        var left = count
        while left > 0 {
            let block = Int(at / Self.length)
            if held.count <= block {
                held += repeatElement(0, count: block + 1 - held.count)
            }
            let taken = min(left, Self.length - held[block])
            held[block] += taken
            at += taken
            left -= taken
        }
    }
}
