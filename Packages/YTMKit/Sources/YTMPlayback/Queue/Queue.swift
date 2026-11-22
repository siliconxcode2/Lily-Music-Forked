import Foundation
import YTMCore

/// What shuffle spreads apart, so one artist's or album's songs don't bunch.
public protocol Spreadable {
    var shuffleArtist: String { get }
    var shuffleAlbum: String { get }
}

/// Shuffle reorders what comes after the current entry, as YouTube Music does, keeping an artist's and an album's
/// songs apart, and turning it off restores the original order. Smart Shuffle's entries are marked so they can be
/// taken out again.
public struct Queue<Element: Hashable & Sendable & Spreadable>: Sendable {
    public struct Entry: Sendable, Identifiable {
        /// Unique within the queue: a row's identity across edits, as the same item may sit in several entries.
        public let id: Int
        public fileprivate(set) var item: Element
        public fileprivate(set) var isRecommended = false
        /// The entry's place in the order shuffling replaced; nil for entries added while shuffled, which
        /// unshuffling keeps behind the entry they followed.
        fileprivate var rank: Int?
    }

    public private(set) var entries: [Entry] = []
    /// How many entries had a place before shuffling; nil when not shuffled.
    private var unshuffledCount: Int?
    private var generator: Xorshift
    public private(set) var currentIndex: Int?
    /// Bumped whenever entries are added, removed or reordered, so views and Smart Shuffle know when to look again.
    public private(set) var revision = 0
    private var nextId = 0

    public init() {
        self.init(seed: .random(in: .min ... .max))
    }

    /// A queue whose shuffles are reproducible, for tests.
    init(seed: UInt64) {
        generator = Xorshift(seed: seed)
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }
    public var current: Element? { currentIndex.map { entries[$0].item } }
    public var items: LazyMapCollection<[Entry], Element> { entries.lazy.map(\.item) }

    public var recommendedIndices: [Int] { entries.indices.filter { entries[$0].isRecommended } }

    public func isRecommended(at index: Int) -> Bool {
        entries.indices.contains(index) && entries[index].isRecommended
    }

    /// A random index below `upperBound` (zero when it is zero), for shuffled starts.
    public mutating func randomBelow(_ upperBound: Int) -> Int {
        Int.random(in: 0..<max(upperBound, 1), using: &generator)
    }

    // MARK: Replacing and shuffling

    public mutating func set(items: some Sequence<Element>, start: Int, shuffle: Bool) {
        entries = []
        entries.reserveCapacity(items.underestimatedCount)
        for item in items { entries.append(entry(item)) }
        currentIndex = entries.isEmpty ? nil : min(max(start, 0), entries.count - 1)
        unshuffledCount = nil
        revision += 1
        guard shuffle else { return }
        rankEntries()
        // Nothing has played yet, so those before the start are shuffled in too.
        if let start = currentIndex {
            entries.insert(entries.remove(at: start), at: 0)
            currentIndex = 0
        }
        shuffleAfterCurrent()
    }

    public mutating func setShuffle(_ on: Bool) {
        switch (on, unshuffledCount) {
        case (true, nil):
            rankEntries()
            shuffleAfterCurrent()
            revision += 1
        case (false, let ranked?):
            unshuffle(ranked: ranked)
            revision += 1
        default:
            break
        }
    }

    /// Records the order shuffling replaces.
    private mutating func rankEntries() {
        for index in entries.indices { entries[index].rank = index }
        unshuffledCount = entries.count
    }

    private mutating func shuffleAfterCurrent() {
        let start = currentIndex.map { $0 + 1 } ?? 0
        let upcoming = Array(entries[start...])
        let order = spread(upcoming.map(\.item), by: [\.shuffleArtist, \.shuffleAlbum])
        entries.replaceSubrange(start..., with: order.map { upcoming[$0] })
        // The spread doesn't see the current entry, so its artist may follow it.
        if let current = currentIndex,
           let other = entries[start...].firstIndex(where: { $0.item.shuffleArtist != entries[current].item.shuffleArtist }) {
            entries.insert(entries.remove(at: other), at: start)
        }
    }

    /// A random order of `items` in which each key's items sit evenly apart from a random offset, with a little
    /// jitter, as a plain shuffle bunches them by chance; within a key, the next key is spread the same way.
    private mutating func spread(_ items: [Element], by keys: ArraySlice<KeyPath<Element, String>>) -> [Int] {
        guard let key = keys.first else { return Array(items.indices).shuffled(using: &generator) }
        // Groups in order of first appearance, as a dictionary's order would make the draws below differ from run
        // to run.
        var index: [String: Int] = [:]
        var groups: [[Int]] = []
        for (at, item) in items.enumerated() {
            let name = item[keyPath: key]
            if let group = index[name] {
                groups[group].append(at)
            } else {
                index[name] = groups.count
                groups.append([at])
            }
        }
        var placed: [(position: Double, index: Int)] = []
        placed.reserveCapacity(items.count)
        for group in groups {
            let order = spread(group.map { items[$0] }, by: keys.dropFirst())
            let gap = 1 / Double(group.count)
            let offset = Double.random(in: 0..<1, using: &generator)
            for (n, member) in order.enumerated() {
                let jitter = 0.4 * Double.random(in: 0..<1, using: &generator) - 0.2
                placed.append(((Double(n) + offset + jitter) * gap, group[member]))
            }
        }
        placed.sort { $0.position < $1.position }
        return placed.map(\.index)
    }

    /// Each entry that had a place leads a run of the entries added while shuffled that follow it, so those stay
    /// behind the entry they followed and the one playing never jumps to the end.
    private mutating func unshuffle(ranked: Int) {
        var runStarts = [Int](repeating: -1, count: ranked)
        for (index, entry) in entries.enumerated() {
            if let rank = entry.rank { runStarts[rank] = index }
        }
        var restored: [Entry] = []
        restored.reserveCapacity(entries.count)
        var restoredCurrent: Int?
        func appendRun(from start: Int) {
            var index = start
            repeat {
                if index == currentIndex { restoredCurrent = restored.count }
                restored.append(entries[index])
                index += 1
            } while index < entries.count && entries[index].rank == nil
        }
        // Entries added while shuffled ahead of every ranked one have nothing to follow, so they lead.
        if entries.first.map({ $0.rank == nil }) == true { appendRun(from: 0) }
        for start in runStarts where start >= 0 { appendRun(from: start) }
        entries = restored
        currentIndex = restoredCurrent
        unshuffledCount = nil
    }

    private mutating func entry(_ item: Element, recommended: Bool = false) -> Entry {
        defer { nextId &+= 1 }
        return Entry(id: nextId, item: item, isRecommended: recommended)
    }

    // MARK: Moving through the queue

    /// The entry `advance` would move to, without moving.
    public func peekNext(repeat mode: RepeatMode) -> Element? {
        nextIndex(user: false, repeat: mode).map { entries[$0].item }
    }

    /// Moves to the next entry; `user` skips leave repeat-one. Returns nil at the end of the queue.
    @discardableResult
    public mutating func advance(user: Bool, repeat mode: RepeatMode) -> Element? {
        guard let next = nextIndex(user: user, repeat: mode) else { return nil }
        currentIndex = next
        return entries[next].item
    }

    private func nextIndex(user: Bool, repeat mode: RepeatMode) -> Int? {
        guard let current = currentIndex else { return nil }
        if mode == .one && !user { return current }
        if current + 1 < entries.count { return current + 1 }
        return mode == .off ? nil : 0
    }

    /// Moves to the previous entry, wrapping to the last only with repeat-all.
    @discardableResult
    public mutating func back(repeat mode: RepeatMode) -> Element? {
        guard let current = currentIndex else { return nil }
        let previous = current > 0 ? current - 1 : mode == .all ? entries.count - 1 : 0
        currentIndex = previous
        return entries[previous].item
    }

    @discardableResult
    public mutating func jump(to index: Int) -> Element? {
        guard entries.indices.contains(index) else { return nil }
        currentIndex = index
        return entries[index].item
    }

    // MARK: Adding

    /// Inserts right after the current entry, or at the end of an empty queue, where it becomes current.
    public mutating func playNext(_ item: Element) {
        let at = currentIndex.map { $0 + 1 } ?? entries.count
        entries.insert(entry(item), at: at)
        revision += 1
        if currentIndex == nil { currentIndex = at }
    }

    /// Adds to the end; the first one added to an empty queue becomes current.
    public mutating func append(contentsOf items: some Sequence<Element>) {
        let start = entries.count
        for item in items { entries.append(entry(item)) }
        guard entries.count > start else { return }
        revision += 1
        if currentIndex == nil { currentIndex = start }
    }

    /// While shuffled, each item goes in at random among the entries still to play, and goes last should shuffle
    /// be turned off; otherwise they are appended.
    public mutating func extend(_ items: some Sequence<Element>) {
        guard var ranked = unshuffledCount else { return append(contentsOf: items) }
        // Behind the entries played next or recommended right after the current, which the order doesn't know, so
        // they still play next.
        let after = currentIndex.map { $0 + 1 } ?? 0
        var start = after + entries[after...].prefix { $0.rank == nil }.count
        let before = entries.count
        for item in items {
            var added = entry(item)
            added.rank = ranked
            ranked += 1
            // A few draws for a place not beside the same artist, as spreading again would reorder what is shown.
            var at = start
            for _ in 0..<4 {
                at = start + randomBelow(entries.count - start + 1)
                if !beside(at, item.shuffleArtist) { break }
            }
            entries.insert(added, at: at)
            if currentIndex == nil {
                // The rest go after it, so the first stays current.
                currentIndex = at
                start = at + 1
            }
        }
        unshuffledCount = ranked
        if entries.count > before { revision += 1 }
    }

    /// Whether an item put in at `at` would sit beside one by `artist`.
    private func beside(_ at: Int, _ artist: String) -> Bool {
        (at > 0 && entries[at - 1].item.shuffleArtist == artist) || (at < entries.count && entries[at].item.shuffleArtist == artist)
    }

    // MARK: Smart Shuffle's recommendations

    /// Marks the entries at `indices` as Smart Shuffle's, as restored from a saved queue.
    public mutating func markRecommended(_ indices: some Sequence<Int>) {
        for index in indices where entries.indices.contains(index) {
            entries[index].isRecommended = true
        }
    }

    /// Puts a recommendation at `index`, which must be after the current entry.
    public mutating func insertRecommended(_ item: Element, at index: Int) {
        guard let current = currentIndex, index > current, index <= entries.count else { return }
        entries.insert(entry(item, recommended: true), at: index)
        revision += 1
    }

    /// Takes out every recommendation but the one playing. Returns whether any was removed.
    @discardableResult
    public mutating func removeRecommended() -> Bool {
        guard let current = currentIndex else { return false }
        return remove(keeping: current) { $1.isRecommended }
    }

    // MARK: Editing

    /// Removes the entries at `indices`, all but the current one. Returns the indices removed, in order.
    @discardableResult
    public mutating func removeMany(_ indices: some Sequence<Int>) -> [Int] {
        guard let current = currentIndex else { return [] }
        var drop = [Bool](repeating: false, count: entries.count)
        for index in indices where index != current && drop.indices.contains(index) {
            drop[index] = true
        }
        let removed = drop.indices.filter { drop[$0] }
        if !removed.isEmpty { remove(keeping: current) { index, _ in drop[index] } }
        return removed
    }

    /// Drops every entry but `current` that `drop` picks; the current index follows its entry.
    @discardableResult
    private mutating func remove(keeping current: Int, where drop: (_ index: Int, _ entry: Entry) -> Bool) -> Bool {
        var kept = 0
        for index in entries.indices where index == current || !drop(index, entries[index]) {
            if index == current { currentIndex = kept }
            entries.swapAt(kept, index)
            kept += 1
        }
        guard kept < entries.count else { return false }
        entries.removeSubrange(kept...)
        revision += 1
        return true
    }

    /// `destination` is an index from before the move, as SwiftUI's `onMove` gives. The current index follows its
    /// entry. Returns whether anything moved.
    @discardableResult
    public mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) -> Bool {
        guard let first = offsets.first, let last = offsets.last, last < entries.count,
              (0...entries.count).contains(destination) else { return false }
        // The moved block lands after the entries that stay ahead of the destination; already there, nothing moves.
        let landing = destination - offsets.count(in: 0..<destination)
        guard first != landing || last != landing + offsets.count - 1 else { return false }
        var reordered: [Entry] = []
        reordered.reserveCapacity(entries.count)
        var movedCurrent: Int?
        func take(_ index: Int) {
            if index == currentIndex { movedCurrent = reordered.count }
            reordered.append(entries[index])
        }
        for index in 0..<destination where !offsets.contains(index) { take(index) }
        for index in offsets { take(index) }
        for index in destination..<entries.count where !offsets.contains(index) { take(index) }
        entries = reordered
        currentIndex = movedCurrent
        revision += 1
        return true
    }

    /// Moves the entries at `indices` to right after the current entry, which never moves.
    @discardableResult
    public mutating func playNextMany(_ indices: some Sequence<Int>) -> Bool {
        guard let current = currentIndex else { return false }
        let valid = entries.indices
        let picked = IndexSet(indices.lazy.filter { $0 != current && valid.contains($0) })
        return move(fromOffsets: picked, toOffset: current + 1)
    }

    /// Keeps the entries' places, so the revision stays. Returns the indices replaced.
    @discardableResult
    public mutating func replace(where matches: (Element) -> Bool, with item: Element) -> [Int] {
        var replaced: [Int] = []
        for index in entries.indices where matches(entries[index].item) {
            entries[index].item = item
            replaced.append(index)
        }
        return replaced
    }

    public mutating func clearUpcoming() {
        guard let current = currentIndex, current + 1 < entries.count else { return }
        entries.removeSubrange((current + 1)...)
        revision += 1
    }
}

extension Track: Spreadable {
    /// By name, as rows don't all carry the artist's ID.
    public var shuffleArtist: String { artists.first?.name ?? "" }
    public var shuffleAlbum: String { album?.name ?? "" }
}

/// xorshift64: tiny, fast and seedable, so tests can pin a shuffle. Not for anything that needs real randomness.
private struct Xorshift: RandomNumberGenerator, Sendable {
    private var state: UInt64

    /// The state must never be zero, or every output would be.
    init(seed: UInt64) {
        state = seed | 1
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
