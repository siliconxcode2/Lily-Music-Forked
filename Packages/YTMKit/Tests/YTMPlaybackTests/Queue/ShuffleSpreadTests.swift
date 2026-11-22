import Testing
@testable import YTMPlayback

/// Three artists in turn and one album, so the other queue tests shuffle much as before.
extension Int: Spreadable {
    public var shuffleArtist: String { String(self % 3) }
    public var shuffleAlbum: String { "" }
}

/// An artist and an album, by index; `n` tells apart songs that share both.
private struct Song: Hashable, Sendable, Spreadable {
    let n: Int
    let artist: Int
    let album: Int

    var shuffleArtist: String { String(artist) }
    var shuffleAlbum: String { String(album) }
}

struct ShuffleSpreadTests {
    /// Ten artists of uneven sizes, none much more than a fifth, each across three albums.
    private func library() -> [Song] {
        var songs: [Song] = []
        for (artist, count) in [60, 47, 41, 33, 29, 23, 19, 13, 11, 7].enumerated() {
            for i in 0..<count { songs.append(Song(n: songs.count, artist: artist, album: i % 3)) }
        }
        return songs
    }

    private func neighbours(_ order: some Collection<Song>, _ same: (Song, Song) -> Bool) -> Int {
        zip(order, order.dropFirst()).filter(same).count
    }

    @Test func spreadsArtistsAndAlbums() {
        let songs = library()
        let n = Double(songs.count)
        let sizes = Dictionary(grouping: songs, by: \.artist).values.map { Double($0.count) }
        // What a plain shuffle averages: (n - 1) times the chance two songs share an artist.
        let plain = (n - 1) * sizes.map { ($0 / n) * ($0 / n) }.reduce(0, +)
        var artists = 0
        var albums = 0
        for seed in 0..<20 {
            var q = Queue<Song>(seed: UInt64(seed))
            q.set(items: songs, start: 0, shuffle: true)
            let order = Array(q.items)
            artists += neighbours(order.dropFirst()) { $0.artist == $1.artist }
            for artist in 0..<10 {
                albums += neighbours(order.filter { $0.artist == artist }) { $0.album == $1.album }
            }
        }
        #expect(Double(artists) * 10 < plain * 20, "\(artists) same-artist neighbours, a plain shuffle averages \(plain * 20)")
        // A plain shuffle puts two of an artist's songs from one album together a third of the time.
        let plainAlbums = Double(songs.count - 10) / 3 * 20
        #expect(Double(albums) * 5 < plainAlbums, "\(albums) same-album neighbours, a plain shuffle averages \(plainAlbums)")
    }

    @Test func keepsTheCurrentAndRestoresTheOrder() throws {
        let songs = library()
        var q = Queue<Song>(seed: 3)
        q.set(items: songs, start: 0, shuffle: false)
        q.jump(to: 40)
        q.setShuffle(true)
        let order = Array(q.items)
        #expect(Array(order.prefix(41)) == Array(songs.prefix(41)), "what has played stays put")
        #expect(order.map(\.n).sorted() == Array(0..<songs.count), "nothing lost or doubled")
        #expect(order[41].artist != order[40].artist, "the current's artist doesn't follow it")
        q.advance(user: false, repeat: .off)
        let playing = try #require(q.current)
        q.setShuffle(false)
        #expect(Array(q.items) == songs)
        #expect(q.current == playing)
    }

    /// As `continuePlaylist` adds each batch, among the songs still to play.
    @Test func aPlaylistArrivingInPagesIsSpreadToo() {
        let songs = library()
        var same = 0
        for seed in 0..<20 {
            var q = Queue<Song>(seed: UInt64(seed))
            q.set(items: songs.prefix(100), start: 0, shuffle: true)
            for start in stride(from: 100, to: songs.count, by: 100) {
                q.extend(songs[start..<min(start + 100, songs.count)])
            }
            same += neighbours(Array(q.items)) { $0.artist == $1.artist }
        }
        // A plain shuffle of these averages about 37 per queue.
        #expect(same < 20 * 12, "\(same) same-artist neighbours in 20 queues")
    }

    @Test func isTheSameForTheSameSeed() {
        func shuffled() -> [Song] {
            var q = Queue<Song>(seed: 7)
            q.set(items: library(), start: 3, shuffle: true)
            q.extend((0..<50).map { Song(n: 300 + $0, artist: $0 % 10, album: 0) })
            return Array(q.items)
        }
        #expect(shuffled() == shuffled())
    }
}
