import Foundation
import Testing
@testable import YTMCore

private func json(_ text: String) throws -> JSON {
    try JSON(data: Data(text.utf8))
}

private func row(_ n: Int) -> String {
    #"{"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"v\#(n)"},"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Song \#(n)"}]}}}]}}"#
}

private let mixTile = #"""
{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"My Mix 1"}]},"subtitle":{"runs":[{"text":"Juice WRLD, MXZI"}]},
  "navigationEndpoint":{"browseEndpoint":{"browseId":"VLRDTMAK5uy_a","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_PLAYLIST"}}}}}}
"""#

private func carousel(_ title: String, _ items: [String]) -> String {
    #"{"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"\#(title)"}]}}},"contents":[\#(items.joined(separator: ","))]}}"#
}

@Suite struct HomeFeedTests {
    @Test func readsCarouselsAndCapsLists() throws {
        let page = try json(#"""
        {"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{
          "contents":[\#(carousel("Quick picks", (1...12).map(row))),
            {"musicTastebuilderShelfRenderer":{"primaryText":{"runs":[{"text":"Tell us what you like"}]}}},
            \#(carousel("Mixed for you", [mixTile]))],
          "continuations":[{"nextContinuationData":{"continuation":"TOKEN"}}]}}}}]}}}
        """#)
        let (sections, next) = try HomeFeed.firstPage(page)
        #expect(next == "TOKEN")
        #expect(sections.map(\.title) == ["Quick picks", "Mixed for you"], "the taste picker is skipped")
        guard case .tracks(let picks) = sections[0], case .cards(let mixes) = sections[1] else {
            Issue.record("expected a track list then a card row")
            return
        }
        #expect(picks.tracks.map(\.id) == (1...HomeFeed.listLimit).map { "v\($0)" })
        #expect(mixes.layout == .carousel && mixes.cards[0].subtitle == "Juice WRLD, MXZI", "subtitles as YouTube words them")
    }

    @Test func readsSongListsAndGridsAmongTheCarousels() throws {
        let page = try json(#"""
        {"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{
          "contents":[{"musicShelfRenderer":{"title":{"runs":[{"text":"Songs for you"}]},"contents":[\#(row(1)),\#(row(2))]}},
            {"gridRenderer":{"header":{"gridHeaderRenderer":{"title":{"runs":[{"text":"Your tiles"}]}}},"items":[\#(mixTile)]}},
            {"musicCardShelfRenderer":{"title":{"runs":[{"text":"Not a shelf of the feed"}]}}}]}}}}]}}}
        """#)
        let sections = try HomeFeed.firstPage(page).sections
        #expect(sections.map(\.title) == ["Songs for you", "Your tiles"])
        guard case .tracks(let songs) = sections[0], case .cards(let tiles) = sections[1] else {
            Issue.record("expected a track list then a card grid")
            return
        }
        #expect(songs.tracks.map(\.id) == ["v1", "v2"])
        #expect(tiles.layout == .grid)
    }

    @Test func countsOnlyOfficialMusicVideosAsVideos() throws {
        func tile(_ id: String, _ type: String) -> String {
            #"{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"\#(id)"}]},"navigationEndpoint":{"watchEndpoint":{"videoId":"\#(id)","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"\#(type)"}}}}}}"#
        }
        let wideRow = #"""
        {"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"w"},
          "thumbnail":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/w/a.jpg","width":400,"height":225}]}}},
          "flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Wide"}]}}}]}}
        """#
        let page = try json(#"""
        {"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{
          "contents":[\#(carousel("Listen again", [tile("omv", "MUSIC_VIDEO_TYPE_OMV"), tile("ugc", "MUSIC_VIDEO_TYPE_UGC")])),
            \#(carousel("Quick picks", [wideRow]))]}}}}]}}}
        """#)
        let sections = try HomeFeed.firstPage(page).sections
        guard sections.count == 2, case .cards(let tiles) = sections[0], case .tracks(let rows) = sections[1] else {
            Issue.record("expected a card row then a track list")
            return
        }
        #expect(tiles.cards.map { $0.track?.isVideo } == [true, false], "uploads play as they are")
        #expect(rows.tracks.map(\.isVideo) == [false], "no type on Home is no video, whatever the thumbnail")
        let elsewhere = try #require(Renderers.track(try json(wideRow)["musicResponsiveListItemRenderer"]))
        #expect(elsewhere.isVideo, "off Home, a wide thumbnail still marks a video")
    }

    @Test func readsContinuationPages() throws {
        let page = try json(#"""
        {"continuationContents":{"sectionListContinuation":{"contents":[\#(carousel("Mixed for you", [mixTile]))],
          "continuations":[{"nextContinuationData":{"continuation":""}}]}}}
        """#)
        let (sections, next) = HomeFeed.nextPage(page)
        #expect(sections.count == 1)
        #expect(next == nil, "an empty token ends the feed")
    }

    @Test func rejectsOtherPages() throws {
        #expect(throws: YTMError.self) { try HomeFeed.firstPage(try json("{}")) }
        let (sections, next) = HomeFeed.nextPage(try json("{}"))
        #expect(sections.isEmpty && next == nil)
    }

    @Test func retriesOnlyRefusals() {
        #expect(HomeFeed.isRefusal(YTMError(.http, "Invalid argument", status: 400)))
        #expect(!HomeFeed.isRefusal(YTMError(.http, "Unauthorised", status: 401)))
        #expect(!HomeFeed.isRefusal(YTMError(.network, "Offline")))
        #expect(!HomeFeed.isRefusal(CancellationError()))
        #expect(HomeFeed.retryDelay(after: 2) == .milliseconds(600))
    }

    @Test func showsListenAgainAsSpeedDial() throws {
        let listenAgain = #"{"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Listen again","navigationEndpoint":{"browseEndpoint":{"browseId":"FEmusic_listen_again"}}}]}}},"contents":[\#(mixTile)]}}"#
        let page = try json(#"{"continuationContents":{"sectionListContinuation":{"contents":[\#(listenAgain),\#(carousel("Mixed for you", [mixTile]))]}}}"#)
        let sections = HomeFeed.nextPage(page).sections
        guard case .cards(let dial) = sections[0], case .cards(let mixes) = sections[1] else {
            Issue.record("expected two card shelves")
            return
        }
        #expect(dial.title == "Speed dial" && dial.layout == .speedDial)
        #expect(mixes.layout == .carousel)
        let unlinked = try json(#"{"continuationContents":{"sectionListContinuation":{"contents":[\#(carousel("Listen again", [mixTile]))]}}}"#)
        guard case .cards(let titled)? = HomeFeed.nextPage(unlinked).sections.first else {
            Issue.record("expected a card shelf")
            return
        }
        #expect(titled.layout == .speedDial, "known by its title when it leads nowhere, as the feed usually sends it")
    }

    private func shelf(_ title: String, _ ids: [String], layout: CardLayout = .carousel) -> Section {
        .cards(CardSection(title: title, cards: ids.map { Card(kind: .album, id: $0, title: $0) }, layout: layout))
    }

    private func dial(_ ids: [String]) -> Section {
        shelf(HomeFeed.speedDialTitle, ids, layout: .speedDial)
    }

    private func ids(_ section: Section) -> [String] {
        switch section {
        case .cards(let s): s.cards.map(\.id)
        case .tracks(let s): s.tracks.map(\.id)
        }
    }

    @Test func arrangesOwnShelvesInOneOrder() {
        let quickPicks = Section.tracks(TrackSection(title: "Quick picks", tracks: [Track(id: "q", title: "q")], mode: .section))
        let arranged = HomeFeed.arranged([
            shelf("Today's biggest hits", ["h"]), quickPicks, shelf("Recaps", ["r"]), dial(["a"]), dial(["b"]),
            shelf("Forgotten favorites", ["f"]), shelf("Browse moods & genres", ["g"], layout: .chips),
        ])
        #expect(arranged.map(\.title) == [HomeFeed.speedDialTitle, "Quick picks", "Forgotten favorites"])
        #expect(ids(arranged[0]) == ["a"], "the first of two with one title")
        guard case .tracks(let picks) = arranged[1] else {
            Issue.record("expected Quick picks as a track list")
            return
        }
        #expect(picks.mode == .radio, "a Quick pick plays with a radio after it")

        let older = HomeFeed.arranged([shelf("Quick picks", ["q"]), shelf("Listen again", ["l"])])
        #expect(older.map(\.title) == [HomeFeed.speedDialTitle, "Quick picks"], "a feed saved before Speed dial has it under its old name")
        guard case .cards(let dial) = older[0] else {
            Issue.record("expected Speed dial's tiles")
            return
        }
        #expect(dial.layout == .speedDial)

        let renamed = HomeFeed.arranged([shelf("Neu", ["n"]), shelf("Alt", ["o"])])
        #expect(renamed.map(\.title) == ["Neu", "Alt"], "kept whole when nothing matches")
    }

    @Test func releasesShelvesFromTheTopDown() {
        var held = [shelf("Forgotten favorites", ["f"]), shelf("Recaps", ["r"]), dial(["a"])]
        var shown = HomeFeed.release(&held, after: [], done: false)
        #expect(shown.map(\.title) == [HomeFeed.speedDialTitle], "Forgotten favorites waits for Quick picks")

        held += [shelf("Mixed for you", ["m"]), shelf("Quick picks", ["q"]), dial(["b"])]
        shown += HomeFeed.release(&held, after: shown, done: false)
        #expect(
            shown.map(\.title) == [HomeFeed.speedDialTitle, "Quick picks", "Forgotten favorites"],
            "Mixed for you waits for Trending songs for you, which may yet come"
        )

        shown += HomeFeed.release(&held, after: shown, done: true)
        #expect(
            shown.map(\.title) == [HomeFeed.speedDialTitle, "Quick picks", "Forgotten favorites", "Mixed for you"],
            "the rest once the feed ends, without the others"
        )
        #expect(ids(shown[0]) == ["a"], "the first of two with one title")
        #expect(held.isEmpty)
    }

    @Test func describesEveryShelfForTheSkeleton() {
        let shelves = YTMusic.homeShelves
        #expect(shelves.map(\.title) == HomeFeed.shelfOrder)
        #expect(shelves.map(\.layout) == [.speedDial, nil, .carousel, nil, .carousel, .carousel])
    }

    @Test func isCompleteOnceEveryShelfHasArrived() {
        let all = HomeFeed.shelfOrder.map { $0 == HomeFeed.speedDialTitle ? dial(["a"]) : shelf($0, ["x"]) }
        #expect(HomeFeed.isComplete(all))
        #expect(!HomeFeed.isComplete(Array(all.dropLast())), "a shelf may yet come")
        #expect(!HomeFeed.isComplete(Array(all.dropFirst())), "Speed dial may yet come")
    }

    @Test func keepsARenamedFeedWholeOnceItEnds() {
        var held = [shelf("Neu", ["n"]), shelf("Alt", ["o"])]
        #expect(HomeFeed.release(&held, after: [], done: false).isEmpty, "nothing yet: Speed dial may come")
        #expect(HomeFeed.release(&held, after: [], done: true).map(\.title) == ["Neu", "Alt"])
    }

    @Test func speedDialMixesInRecentPlays() throws {
        let recent = [
            Track(id: "c", title: "c", thumbnail: "https://lh3.googleusercontent.com/c=w120-h120-l90-rj"),
            Track(id: "d", title: "d"),
        ]
        let played = ["c", "x", "y", "z"].map { Track(id: $0, title: $0) }
        let sections = HomeFeed.addingRecent([dial(["a", "b", "c", "d", "e", "f", "g"]), shelf("Mixed for you", ["m"])], recent: played)
        #expect(
            ids(sections[0]) == ["a", "b", "c", "x", "d", "e", "f"],
            "YouTube's lead, one recent play after every three, c left where it was, length kept"
        )
        #expect(ids(sections[1]) == ["m"])

        let five = ["r1", "r2", "r3", "r4", "r5"].map { Track(id: $0, title: $0) }
        let shown = ids(HomeFeed.addingRecent([dial((0..<19).map { String($0) })], recent: five)[0])
        #expect(shown.count == 19)
        #expect(shown.indices.filter { shown[$0].hasPrefix("r") } == [3, 7, 11, 15], "as many as fit, never first")
        let six = (1...6).map { Track(id: "r\($0)", title: "") }
        let long = ids(HomeFeed.addingRecent([dial((0..<24).map { String($0) })], recent: six)[0])
        #expect(long.indices.filter { long[$0].hasPrefix("r") } == [3, 7, 11, 15, 19], "at most five")

        let made = HomeFeed.addingRecent([shelf("Quick picks", ["q"])], recent: recent)
        #expect(made.map(\.title) == [HomeFeed.speedDialTitle, "Quick picks"], "made when the feed has none")
        #expect(ids(made[0]) == ["c", "d"])
        guard case .cards(let tiles) = made[0] else {
            Issue.record("expected Speed dial's tiles")
            return
        }
        #expect(tiles.cards[0].kind == .song && tiles.cards[0].track?.id == "c")
        #expect(tiles.cards[0].thumbnail == Thumbnail.resized("https://lh3.googleusercontent.com/c=w120-h120-l90-rj", edge: Thumbnail.card))

        let none = HomeFeed.addingRecent([dial(["a"])], recent: [])
        #expect(ids(none[0]) == ["a"], "unchanged with nothing played")

        let many = (0..<15).map { Track(id: "p\($0)", title: "") }
        #expect(ids(HomeFeed.addingRecent([dial(["a"])], recent: many)[0]) == ["a"], "no slot within one pick")
        #expect(ids(HomeFeed.addingRecent([], recent: many)[0]).count == HomeFeed.recentShelf)
    }

    @Test func dropsAListRepeatingAnEarlierOne() {
        func list(_ title: String, _ ids: [String]) -> Section {
            .tracks(TrackSection(title: title, tracks: ids.map { Track(id: $0, title: $0) }, mode: .radio))
        }
        let copied = HomeFeed.withoutRepeats([
            dial(["a"]), list("Quick picks", ["a", "q", "r"]), list("Trending songs for you", ["q", "r"]), shelf("Mixed for you", ["q"]),
        ])
        #expect(copied.map(\.title) == [HomeFeed.speedDialTitle, "Quick picks", "Mixed for you"], "a copy goes; cards are never compared")
        #expect(ids(copied[1]) == ["a", "q", "r"])

        let shared = HomeFeed.withoutRepeats([list("Quick picks", ["q", "r"]), list("Trending songs for you", ["r", "t"])])
        #expect(ids(shared[1]) == ["t"], "only the songs already shown go")
    }
}

@Suite struct ExploreTests {
    private func chip(_ name: String, _ params: String, colour: Int) -> String {
        #"{"musicNavigationButtonRenderer":{"buttonText":{"runs":[{"text":"\#(name)"}]},"solid":{"leftStripeColor":\#(colour)},"clickCommand":{"browseEndpoint":{"browseId":"FEmusic_moods_and_genres_category","params":"\#(params)"}}}}"#
    }

    @Test func splitsMoodsFromGenres() throws {
        let page = try json(#"""
        {"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[
          {"gridRenderer":{"items":[\#(chip("For you", "x", colour: 0))]}},
          {"gridRenderer":{"items":[\#(chip("Chill", "c", colour: 4288988671)), \#(chip("Focus", "f", colour: 4278190080))]}},
          {"gridRenderer":{"items":[\#(chip("Blues", "b", colour: 4278232339))]}}]}}}}]}}}
        """#)
        let chips = try MoodsAndGenres(page)
        #expect(chips.moods.map(\.title) == ["Chill", "Focus"], "the last two grids, moods first")
        #expect(chips.genres.map(\.id) == ["b"])
        #expect(chips.moods[0].color == 0xA4C5FF)
        #expect(chips.all.map(\.title) == ["Chill", "Focus", "Blues"])
    }

    @Test func refusesAReplyWithoutChips() throws {
        let error = #"{"error":{"code":400,"message":"Request contains an invalid argument."}}"#
        #expect(throws: YTMError.self, "so the session cache doesn't keep it") { try MoodsAndGenres(try json(error)) }
    }

    @Test func findsTrendingAndTopArtists() {
        let song = { (id: String) in Track(id: id, title: id) }
        let sections: [Section] = [
            .tracks(TrackSection(title: "Top songs", tracks: [song("top")], mode: .section, more: .playlist("PLtop"))),
            .tracks(TrackSection(title: "Trending", tracks: [song("trend")], mode: .section, more: .playlist("PLtrend"))),
            .cards(CardSection(title: "Video charts", cards: [
                Card(kind: .playlist, id: "PL100", title: "Top 100 Music Videos"),
                Card(kind: .playlist, id: "OLAKtrend", title: "Trending 20 United Kingdom"),
            ], layout: .carousel)),
            .cards(CardSection(title: "Top artists", cards: [Card(kind: .artist, id: "UCa", title: "A")], layout: .carousel)),
        ]
        let charts = Charts(sections)
        #expect(charts.trendingPlaylistId == "OLAKtrend")
        #expect(charts.trendingTracks.map(\.id) == ["trend"], "the second chart list")
        #expect(charts.artists.map(\.id) == ["UCa"])
    }

    @Test func sharesOneFetchAndForgetsFailures() async throws {
        let counter = Counter()
        let cache = SessionCache<Int>()
        await #expect(throws: YTMError.self) {
            try await cache.value {
                _ = await counter.next()
                throw YTMError(.network, "Offline")
            }
        }
        let fetch: @Sendable () async throws -> Int = {
            try await Task.sleep(for: .milliseconds(50))
            return await counter.next()
        }
        async let first = cache.value(fetch)
        async let second = cache.value(fetch)
        let values = try await [first, second]
        #expect(values == [2, 2], "the failure was not kept; the two callers shared one fetch")
        #expect(try await cache.value(fetch) == 2)
        #expect(await counter.calls == 2)
    }
}

private actor Counter {
    var calls = 0

    func next() -> Int {
        calls += 1
        return calls
    }
}

@Suite struct LibraryPagesTests {
    private let albumTile = #"""
    {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Discovery"}]},
      "subtitle":{"runs":[{"text":"Album"},{"text":" • "},{"text":"Daft Punk","navigationEndpoint":{"browseEndpoint":{"browseId":"UCdp"}}},{"text":" • "},{"text":"2001"}]},
      "navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_d","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}}}}}
    """#

    @Test func readsFirstAndLaterPages() throws {
        let first = try json(#"""
        {"continuationContents":{"sectionListContinuation":{"contents":[
          {"itemSectionRenderer":{"contents":[]}},
          {"gridRenderer":{"items":[\#(albumTile)],"continuations":[{"nextContinuationData":{"continuation":"MORE"}}]}}]}}}
        """#)
        let shelf = LibraryList.shelf(in: first)
        #expect(Renderers.continuation(shelf) == "MORE")
        let albums = Renderers.cards(LibraryList.items(shelf))
        #expect(albums.count == 1)
        #expect(albums.first?.kind == .album && albums.first?.subtitle == "Album • Daft Punk • 2001")

        let later = try json(#"{"continuationContents":{"musicShelfContinuation":{"contents":[\#(row(1)), \#(row(2))]}}}"#)
        let rows = LibraryList.shelf(in: later)
        #expect(Renderers.tracks(LibraryList.items(rows)).count == 2 && Renderers.continuation(rows) == nil)
    }

    @Test func mapsRoutes() {
        for list in LibraryList.allCases {
            #expect(LibraryList(list.route) == list)
        }
        #expect(LibraryList(.library) == nil)
    }

    @Test func pinnedPlaylistsLeadInTheOrderPinned() throws {
        let playlists = ["a", "b", "c", "d"].map { Card(kind: .playlist, id: $0, title: $0) }
        let albums = Section.cards("Albums", [Card(kind: .album, id: "b", title: "b"), Card(kind: .album, id: "x", title: "x")], layout: .grid)
        let page = Page(sections: [Section.cards("Playlists", playlists, layout: .grid), albums].compactMap(\.self))
        let pinned = page.withPinnedFirst(["d", "gone", "b"])
        let lead = try #require(pinned.sections.first.flatMap { if case .cards(let s) = $0 { s } else { nil } })
        #expect(lead.cards.map(\.id) == ["d", "b", "a", "c"])
        #expect(pinned.sections.last == page.sections.last, "only the playlists move")
    }

    private func likedPage(rows: [String], more: Bool) -> String {
        let trailing = more ? #",{"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"T"}}}}"# : ""
        return #"""
        {"contents":{"twoColumnBrowseResultsRenderer":{
          "tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"musicResponsiveHeaderRenderer":{
            "title":{"runs":[{"text":"Liked music"}]},
            "secondSubtitle":{"runs":[{"text":"1,234 songs"},{"text":" • "},{"text":"70+ hours"}]},
            "thumbnail":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://www.gstatic.com/youtube/media/ytm/images/pbg/liked-music@576.png","width":576}]}}}}}]}}}}],
          "secondaryContents":{"sectionListRenderer":{"contents":[{"musicPlaylistShelfRenderer":{"contents":[\#(rows.joined(separator: ","))\#(trailing)]}}]}}}}}
        """#
    }

    @Test func countsLikedMusic() throws {
        let long = try #require(LibraryList.likedMusicCard(try json(likedPage(rows: [row(1)], more: true))))
        #expect(long.id == "LM" && long.title == "Liked music")
        #expect(long.subtitle == "Auto playlist • 1234 songs", "the header's count when not all are listed")
        #expect(long.thumbnail == "https://www.gstatic.com/youtube/media/ytm/images/pbg/liked-music@576.png")

        let short = try #require(LibraryList.likedMusicCard(try json(likedPage(rows: [row(1), row(2)], more: false))))
        #expect(short.subtitle == "Auto playlist • 2 songs", "the songs listed when they all are")

        #expect(LibraryList.likedMusicCard(try json("{}")) == nil)
    }
}

@Suite struct HistoryPageTests {
    @Test func joinsEveryDaysShelf() throws {
        let page = try json(#"""
        {"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[
          {"musicShelfRenderer":{"title":{"runs":[{"text":"Today"}]},"contents":[\#(row(1)), \#(row(2))]}},
          {"musicShelfRenderer":{"title":{"runs":[{"text":"Yesterday"}]},"contents":[\#(row(3))]}}]}}}}]}}}
        """#)
        #expect(YTMusic.historyTracks(in: page).map(\.id) == ["v1", "v2", "v3"])
        #expect(YTMusic.historyTracks(in: try json("{}")).isEmpty)
    }
}
