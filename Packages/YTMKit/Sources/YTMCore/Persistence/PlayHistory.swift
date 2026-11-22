import Foundation

/// The songs played on this phone, newest first, one entry per song.
public struct PlayHistory: Codable, Sendable {
    static let limit = 500

    public private(set) var tracks: [Track]
    /// Songs whose latest play has not yet counted.
    public private(set) var skipped: Set<String>

    /// Keeps the newest play of each song, up to the limit.
    public init(tracks: [Track] = [], skipped: Set<String> = []) {
        var seen = Set<String>()
        self.tracks = []
        for track in tracks where seen.insert(track.id).inserted {
            self.tracks.append(track)
            if self.tracks.count == Self.limit { break }
        }
        self.skipped = skipped.intersection(seen)
    }

    /// Cleaned as `init(tracks:)` cleans, so a hand-edited file can't bring in repeats. A file from
    /// before skips were kept counts every play as heard.
    public init(from decoder: any Decoder) throws {
        let file = try decoder.container(keyedBy: CodingKeys.self)
        var skipped = Set<String>()
        file.read(&skipped, .skipped)
        self.init(tracks: try file.decode([Track].self, forKey: .tracks), skipped: skipped)
    }

    /// Those heard long enough to count, newest first.
    public var heard: [Track] {
        tracks.filter { !skipped.contains($0.id) }
    }

    /// Puts `track` first, left out of `heard` until `markHeard`.
    public mutating func record(_ track: Track) {
        tracks.removeAll { $0.id == track.id }
        tracks.insert(track, at: 0)
        skipped.insert(track.id)
        if tracks.count > Self.limit {
            for dropped in tracks[Self.limit...] { skipped.remove(dropped.id) }
            tracks.removeLast(tracks.count - Self.limit)
        }
    }

    public mutating func markHeard(_ id: String) {
        skipped.remove(id)
    }
}
