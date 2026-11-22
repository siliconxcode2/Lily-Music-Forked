import Foundation
@testable import YTMCore

enum CatalogueChecks {
    static func run(_ report: Report) async {
        await report.check("page album") { findings in
            let page = try await Live.api.page(.album(Live.album))
            findings.audit(page, "album")
            guard let header = page.header, case .tracks(let list)? = page.sections.first else {
                return findings.fail("album: no header or track list")
            }
            findings.expect(header.label == "Album" && header.title == "Random Access Memories" && header.subtitle == "Daft Punk",
                            "album header: \(header.label) / \(header.title) / \(header.subtitle)")
            findings.expect(header.meta.hasPrefix("2013 • \(Live.albumTracks) songs • "), "album meta: \(header.meta)")
            findings.expect(header.radioId == header.playlistId.map { "RDAMPL" + $0 }, "album: radio \(header.radioId ?? "none")")
            findings.expect(list.numbered && list.mode == .section && list.tracks.count == Live.albumTracks, "album tracks: \(list.tracks.count), numbered \(list.numbered)")
            findings.expect(list.tracks.allSatisfy { !$0.isVideo && $0.album?.id == Live.album }, "album: a video, or a track not on the album")
            findings.expect(list.tracks.first { $0.title.hasPrefix("Get Lucky") }?.artists.map(\.name) == ["Daft Punk", "Pharrell Williams", "Nile Rodgers"],
                            "album › Get Lucky: artists not all three")
            findings.kinds(page.cards("Other versions"), .album, "album › Other versions")
        }

        var more: Route?
        var artistCard: Card?
        await report.check("page artist (by alias)") { findings in
            let page = try await Live.api.page(.artist(Live.artistAlias))
            findings.audit(page, "artist", minimumSections: 4)
            guard let header = page.header else { return findings.fail("artist: no header") }
            findings.expect(header.label == "Artist" && header.title == "Daft Punk" && header.banner, "artist header: \(header)")
            findings.expect(header.subtitle.hasSuffix(" subscribers"), "artist subtitle: \(header.subtitle)")
            findings.expect(header.radioId?.hasPrefix("RD") == true && header.shufflePlaylistId != nil, "artist: no radio or shuffle playlist")
            findings.titles(page, ["Songs", "Albums", "Singles & EPs", "Fans might also like"])
            findings.kinds(page.cards("Albums") + page.cards("Singles & EPs"), .album, "artist releases")
            findings.kinds(page.cards("Fans might also like"), .artist, "artist › Fans might also like")
            findings.kinds(page.cards("Featured on"), .playlist, "artist › Featured on")
            let albums = page.cards("Albums")
            findings.expect(albums.contains { $0.id == Live.album }, "artist › Albums: no Random Access Memories")
            findings.expect(albums.allSatisfy { $0.subtitle.hasPrefix("Album • Daft Punk") }, "artist › Albums: subtitles \(albums.prefix(3).map(\.subtitle))")
            if case .cards(let row)? = page.section("Albums") { more = row.more }
            artistCard = Card(kind: .artist, id: Live.artist, title: header.title)
            findings.note(page.summary)
        }

        await report.check("page browse (artist's albums)") { findings in
            guard case .browse(let id, _)? = more, let more else { return findings.fail("the artist's Albums has no browse More: \(String(describing: more))") }
            findings.expect(id.hasPrefix("MPAD"), "more: \(id) isn't a discography")
            let page = try await Live.api.page(more)
            findings.audit(page, "albums")
            findings.expect(page.header?.title == "Daft Punk", "albums header: \(page.header?.title ?? "none")")
            for case .cards(let row) in page.sections {
                findings.kinds(row.cards, .album, "albums › \(row.title)")
                findings.expect(row.cards.allSatisfy { $0.subtitle.contains("Daft Punk") }, "albums: subtitles without the artist")
            }
            findings.note(page.summary)
        }

        var playlistCard: Card?
        await report.check("page playlist") { findings in
            // An album's playlist, which comes without a header of its own.
            let album = try await Live.api.page(.album(Live.album))
            guard let id = album.header?.playlistId else { return findings.fail("the album has no playlist") }
            let page = try await Live.api.page(.playlist(id))
            findings.audit(page, "playlist")
            guard let header = page.header else { return findings.fail("playlist: no header") }
            findings.expect(header.label == "Playlist" && header.title == "Random Access Memories", "playlist header: \(header.label) \(header.title)")
            findings.expect(header.radioId == "RDAMPL" + id && header.playlistId == id, "playlist: radio or ID")
            findings.expect(header.meta == "\(Live.albumTracks) songs • 1 hr 15 min", "playlist meta: \(header.meta)")
            findings.expect(page.headerTracks.map(\.id) == album.headerTracks.map(\.id), "playlist: not the album's tracks")
            playlistCard = Card(kind: .playlist, id: id, title: header.title)
            // YouTube Music's own playlists, which every genre lists.
            do {
                _ = try await Live.api.page(.playlist(Live.playlist))
            } catch let error as YTMError where error.kind == .notFound {
                findings.note("YouTube refuses its own RDCLAK playlists signed out: \(error)")
            }
        }

        await report.check("page long playlist + loadMore") { findings in
            var page = try await Live.api.page(.playlist(Live.longPlaylist))
            let first = page.headerTracks.count
            var steps = 0
            while page.more != nil, steps < 10 {
                page = try await Live.api.loadMore(page)
                steps += 1
            }
            findings.audit(page, "long playlist")
            let total = page.headerTracks.count
            let stated = page.header?.count ?? 0
            findings.expect(page.more == nil, "loadMore didn't finish in \(steps) steps")
            findings.expect(first == 100 && steps >= 1, "first batch \(first), \(steps) steps")
            findings.expect(total == min(stated, YTMusic.playlistLimit), "\(total) tracks loaded, the header says \(stated)")
            findings.note("\(first) then \(total) tracks in \(steps) more steps; header \(page.header?.meta ?? "")")
        }

        await report.check("tracks(of:) every card kind") { findings in
            let album = try await Live.api.tracks(of: Card(kind: .album, id: Live.album, title: "Random Access Memories"))
            findings.expect(album.count == Live.albumTracks, "album card: \(album.count) tracks")
            if let playlistCard {
                let tracks = try await Live.api.tracks(of: playlistCard)
                findings.expect(tracks.count == Live.albumTracks, "playlist card: \(tracks.count) tracks")
                findings.audit(tracks, "playlist card")
            }
            if let artistCard {
                let tracks = try await Live.api.tracks(of: artistCard)
                findings.expect(!tracks.isEmpty, "artist card: no tracks")
                findings.audit(tracks, "artist card")
                findings.note("artist card: \(tracks.count) tracks, \(tracks.filter(\.isVideo).count) of them videos")
            }
            let genre = try await Live.api.tracks(of: Card(kind: .genre, id: "x", title: "Pop"))
            let song = try await Live.api.tracks(of: Card(kind: .song, id: Live.songs[0].id, title: "", track: Live.songs[0].track))
            findings.expect(genre.isEmpty && song.isEmpty, "genre or song cards queue tracks of their own")
            findings.note("album \(album.count), playlist and artist as above")
        }

        await report.check("songVersion") { findings in
            let song = try await Live.api.songVersion(of: Live.musicVideo.track)
            findings.expect(song?.id == Live.songOfVideo && song?.isVideo == false, "the song of the video: \(song.map { "\($0.id) \($0.title)" } ?? "none")")
            let none = try await Live.api.songVersion(of: Track(id: "aaaaaaaaaaa", title: "Never Gonna Give You Up (Slowed)", artists: [ArtistRef(id: nil, name: "Rick Astley")], isVideo: true))
            findings.expect(none == nil, "an edit was given a song version: \(none?.title ?? "")")
        }
    }
}
