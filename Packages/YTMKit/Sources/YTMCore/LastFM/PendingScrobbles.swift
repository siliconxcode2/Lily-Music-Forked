extension LastFM {
    /// Plays Last.fm has yet to accept, oldest first, kept on disk.
    struct Pending: Codable, Sendable {
        /// Most scrobbles Last.fm takes in one request.
        static let batchSize = 50
        /// A fortnight of heavy listening: Last.fm refuses plays more than two
        /// weeks old anyway.
        static let limit = 3000

        private(set) var plays: [Play] = []
        /// The account the plays were heard under, so they never go to
        /// another that connects after its access was revoked.
        private(set) var account: String?

        var isEmpty: Bool { plays.isEmpty }

        mutating func push(_ play: Play) {
            if plays.count >= Self.limit { plays.removeFirst(plays.count - Self.limit + 1) }
            plays.append(play)
        }

        mutating func clear() {
            plays.removeAll()
        }

        /// Holds the plays for `account`, dropping any heard under another.
        mutating func hold(for account: String) {
            guard self.account != account else { return }
            if self.account != nil { clear() }
            self.account = account
        }

        /// The oldest plays, as many as go in one request, or just the oldest.
        func batch(one: Bool) -> [Play] {
            Array(plays.prefix(one ? 1 : Self.batchSize))
        }

        /// Matched by value rather than position, as the oldest play may have
        /// made way for a new one while they were on their way.
        mutating func remove(_ sent: [Play]) {
            let sent = Set(sent)
            plays.removeAll { sent.contains($0) }
        }
    }
}
