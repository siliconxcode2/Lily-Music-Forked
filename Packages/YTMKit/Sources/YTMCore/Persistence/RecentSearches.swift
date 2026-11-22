import Foundation

/// The last few searches, newest first.
public struct RecentSearches: Codable, Sendable {
    static let limit = 5

    public private(set) var queries: [String]

    /// Replays `queries` oldest first through `record`, so blanks, repeats
    /// and more than the limit never get in.
    public init(queries: [String] = []) {
        self.queries = []
        for query in queries.reversed() { record(query) }
    }

    public init(from decoder: any Decoder) throws {
        let file = try decoder.container(keyedBy: CodingKeys.self)
        self.init(queries: try file.decode([String].self, forKey: .queries))
    }

    /// Puts `query` first, dropping an earlier search for it whatever its capitals.
    public mutating func record(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, queries.first != query else { return }
        remove(query)
        queries.insert(query, at: 0)
        if queries.count > Self.limit { queries.removeLast(queries.count - Self.limit) }
    }

    /// Drops `query`, whatever its capitals.
    public mutating func remove(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        queries.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
    }
}
