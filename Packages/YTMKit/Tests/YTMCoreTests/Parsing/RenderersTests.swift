import Foundation
import Testing
@testable import YTMCore

private func json(_ text: String) throws -> JSON {
    try JSON(data: Data(text.utf8))
}

/// A carousel of tiles, one malformed, and a carousel of list items.
private let homePage = #"""
{"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{
  "contents":[
    {"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Listen again"}]}}},
      "contents":[
        {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Matt Hardy 999"}]},
          "subtitle":{"runs":[{"text":"Song"},{"text":" • "},{"text":"Trippie Redd","navigationEndpoint":{"browseEndpoint":{"browseId":"UCa"}}},{"text":" & "},{"text":"Juice WRLD","navigationEndpoint":{"browseEndpoint":{"browseId":"UCb"}}}]},
          "thumbnailRenderer":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://lh3.googleusercontent.com/x=w226-h226","width":226}]}}},
          "navigationEndpoint":{"watchEndpoint":{"videoId":"44zDzdf08s4",
            "watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_OMV"}}}}}},
        {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Broken"}]},"navigationEndpoint":{"watchEndpoint":{}}}},
        {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"My Supermix"}]},"subtitle":{"runs":[{"text":"Juice WRLD, MXZI"}]},
          "navigationEndpoint":{"browseEndpoint":{"browseId":"VLRDTMAK5uy_kset","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_PLAYLIST"}}}}}}
      ]}},
    {"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Quick picks"}]}}},
      "contents":[
        {"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"TjsfgUkT0eg"},
          "overlay":{"musicItemThumbnailOverlayRenderer":{"content":{"musicPlayButtonRenderer":{"playNavigationEndpoint":{"watchEndpoint":{"videoId":"TjsfgUkT0eg",
            "watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_ATV"}}}}}}}},
          "flexColumns":[
            {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Plug Walk"}]}}},
            {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Rich The Kid","navigationEndpoint":{"browseEndpoint":{"browseId":"UCr"}}},{"text":" • "},{"text":"565M plays"}]}}},
            {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"The World Is Yours","navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_1",
              "browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}}}}]}}}]}}
      ]}}
  ],
  "continuations":[{"nextContinuationData":{"continuation":"TOKEN"}}]}}}}]}}}
"""#

@Suite struct ShelfTests {
    @Test func parsesCardAndTrackShelves() throws {
        let list = Renderers.sectionList(in: try json(homePage))
        #expect(Renderers.continuation(list) == "TOKEN")
        let sections = Renderers.sections(list, context: ItemContext(subtitles: .asShown))
        guard case .cards(let listen)? = sections.first, case .tracks(let picks)? = sections.last else {
            Issue.record("expected a card shelf then a track shelf")
            return
        }
        #expect(listen.title == "Listen again" && listen.layout == .carousel)
        #expect(listen.cards.count == 2, "the item in an unexpected shape is skipped")
        #expect(listen.cards[0].kind == .song)
        #expect(listen.cards[0].subtitle == "Song • Trippie Redd & Juice WRLD")
        let song = try #require(listen.cards[0].track)
        #expect(song.id == "44zDzdf08s4" && song.isVideo)
        #expect(song.artistNames == "Trippie Redd, Juice WRLD")
        #expect(song.thumbnail == "https://lh3.googleusercontent.com/x=w120-h120-l90-rj")
        #expect(listen.cards[1].kind == .playlist && listen.cards[1].id == "RDTMAK5uy_kset", "the VL prefix is dropped")
        #expect(listen.cards[1].subtitle == "Juice WRLD, MXZI")

        #expect(picks.title == "Quick picks" && picks.mode == .section && !picks.numbered)
        let track = picks.tracks[0]
        #expect(track.title == "Plug Walk" && track.artistNames == "Rich The Kid")
        #expect(track.album == AlbumRef(id: "MPREb_1", name: "The World Is Yours"))
        #expect(!track.isVideo && track.duration == nil)
    }

    @Test func readsContinuationPagesAndTokens() throws {
        let page = try json(#"""
        {"continuationContents":{"sectionListContinuation":{
          "contents":[{"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Mixed for you"}]}}},
            "contents":[{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"My Mix 1"}]},
              "navigationEndpoint":{"browseEndpoint":{"browseId":"VLRDTMAK5uy_a","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_PLAYLIST"}}}}}}]}}],
          "continuations":[{"nextContinuationData":{"continuation":""}}]}}}
        """#)
        let list = Renderers.sectionList(in: page)
        #expect(Renderers.sections(list).count == 1)
        #expect(Renderers.continuation(list) == nil, "an empty token ends the feed")

        let appended = try json(#"""
        {"onResponseReceivedActions":[{"appendContinuationItemsAction":{"continuationItems":[
          {"musicResponsiveListItemRenderer":{}},
          {"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"NEXT"}}}}]}}]}
        """#)
        let (items, token) = Renderers.continuationItems(in: appended)
        #expect(items.count == 2 && token == "NEXT")
        #expect(Renderers.token(try json(#"{"commandExecutorCommand":{"commands":[{"a":1},{"continuationCommand":{"token":"T"}}]}}"#)) == "T")
    }

    @Test func gridsOfGenresAreChipsWithTheirColours() throws {
        let grid = try json(#"""
        {"gridRenderer":{"header":{"gridHeaderRenderer":{"title":{"runs":[{"text":"Genres"}]}}},"items":[
          {"musicNavigationButtonRenderer":{"buttonText":{"runs":[{"text":"Chill"}]},"solid":{"leftStripeColor":4288988671},
            "clickCommand":{"browseEndpoint":{"browseId":"FEmusic_moods_and_genres_category","params":"ggMPOg1uX1JOQW"}}}},
          {"musicNavigationButtonRenderer":{"buttonText":{"runs":[{"text":"Charts"}]},"clickCommand":{"browseEndpoint":{"browseId":"FEmusic_charts"}}}}]}}
        """#)
        guard case .cards(let section)? = Renderers.section(grid) else {
            Issue.record("expected cards")
            return
        }
        #expect(section.layout == .chips && section.title == "Genres")
        #expect(section.cards.map(\.title) == ["Chill"], "navigation buttons are not genres")
        #expect(section.cards[0].color == 0xa4c5ff && section.cards[0].route == .genre("ggMPOg1uX1JOQW"))
    }
}

@Suite struct ItemTests {
    @Test func readsSearchResultSongs() throws {
        let item = try json(#"""
        {"flexColumnDisplayStyle":"MUSIC_RESPONSIVE_LIST_ITEM_FLEX_COLUMN_DISPLAY_STYLE_TWO_LINE_STACK",
         "thumbnail":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/x/a.jpg","width":120,"height":120}]}}},
         "flexColumns":[
          {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Girls","navigationEndpoint":{"watchEndpoint":{"videoId":"vid",
            "watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_ATV"}}}}}]}}},
          {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Song"},{"text":" • "},
            {"text":"aespa","navigationEndpoint":{"browseEndpoint":{"browseId":"UCaespa","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}}}},
            {"text":" • "},{"text":"Girls - The 2nd Mini Album","navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_g","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}}}},
            {"text":" • "},{"text":"4:01"}]}}}]}
        """#)
        let track = try #require(Renderers.track(item))
        #expect(track.id == "vid" && track.title == "Girls")
        #expect(track.artists == [ArtistRef(id: "UCaespa", name: "aespa")])
        #expect(track.album?.id == "MPREb_g" && track.duration == 241)
        #expect(!track.isVideo)
    }

    @Test func fillsAlbumTracksFromTheirPage() throws {
        let item = try json(#"""
        {"index":{"runs":[{"text":"3"}]},"playlistItemData":{"videoId":"v3","playlistSetVideoId":"S3"},
         "flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Track"}]}}}],
         "fixedColumns":[{"musicResponsiveListItemFixedColumnRenderer":{"text":{"runs":[{"text":"3:32"}]}}}]}
        """#)
        let album = AlbumRef(id: "MPREb_a", name: "The Album")
        let artist = ArtistRef(id: "UCx", name: "Someone")
        let track = try #require(Renderers.track(item, context: ItemContext(album: album, artists: [artist])))
        #expect(track.trackNumber == 3 && track.duration == 212)
        #expect(track.album == album && track.artists == [artist] && !track.isVideo)
        #expect(Renderers.track(try json(#"{"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"No ID"}]}}}]}"#)) == nil)
    }

    @Test func composesCardSubtitlesAsYTMNative() throws {
        let album = try json(#"""
        {"flexColumns":[
          {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Next Level"}]}}},
          {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Single"},{"text":" • "},
            {"text":"aespa","navigationEndpoint":{"browseEndpoint":{"browseId":"UCaespa","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}}}},
            {"text":" • "},{"text":"2021"}]}}}],
         "navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_n","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}}}}
        """#)
        let card = try #require(Renderers.listCard(album))
        #expect(card.kind == .album && card.subtitle == "Single • aespa • 2021")

        let artist = try json(#"""
        {"title":{"runs":[{"text":"Test Shot Starfish"}]},"subtitle":{"runs":[{"text":"1.66K subscribers"}]},
         "navigationEndpoint":{"browseEndpoint":{"browseId":"UCt","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}}}}
        """#)
        #expect(Renderers.twoRowCard(artist)?.subtitle == "1.7K subscribers")

        let single = try json(#"""
        {"title":{"runs":[{"text":"One"}]},"subtitle":{"runs":[{"text":"2022"}]},
         "navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_o","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}}}}
        """#)
        let context = ItemContext(artists: [ArtistRef(id: "UCx", name: "Someone")], albumType: .single)
        #expect(Renderers.twoRowCard(single, context: context)?.subtitle == "Single • Someone • 2022")

        let playlist = try json(#"""
        {"title":{"runs":[{"text":"Hits"}]},"subtitle":{"runs":[{"text":"Playlist"},{"text":" • "},{"text":"YouTube Music"},{"text":" • "},{"text":"53 songs"}]},
         "navigationEndpoint":{"browseEndpoint":{"browseId":"VLPLx","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_PLAYLIST"}}}}}
        """#)
        #expect(Renderers.twoRowCard(playlist)?.subtitle == "Playlist • 53 songs")
    }

    @Test func skipsBuiltInPlaylistsAndPodcasts() throws {
        let liked = try json(#"""
        {"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Liked music"}]}}}],
         "navigationEndpoint":{"browseEndpoint":{"browseId":"VLLM","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_PLAYLIST"}}}}}
        """#)
        #expect(Renderers.listCard(liked) == nil)
        let podcast = try json(#"""
        {"title":{"runs":[{"text":"A show"}]},
         "navigationEndpoint":{"browseEndpoint":{"browseId":"MPSPx","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE"}}}}}
        """#)
        #expect(Renderers.twoRowCard(podcast) == nil)
    }

    @Test func tellsVideosByTheirType() throws {
        func isVideo(_ type: String) throws -> Bool? {
            Renderers.isVideo(try json(#"{"watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"\#(type)"}}}"#))
        }
        #expect(try isVideo("MUSIC_VIDEO_TYPE_UGC") == true)
        #expect(try isVideo("MUSIC_VIDEO_TYPE_OMV") == true)
        #expect(try isVideo("MUSIC_VIDEO_TYPE_ATV") == false)
        #expect(try isVideo("MUSIC_VIDEO_TYPE_PODCAST_EPISODE") == false, "an episode has no song version")
        #expect(Renderers.isVideo(try json("{}")) == nil)
    }

    @Test func mapsEndpointsToRoutes() throws {
        func route(_ text: String) throws -> Route? { Renderers.route(try json(text)) }
        #expect(try route(#"{"browseEndpoint":{"browseId":"MPREb_x","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}}}"#) == .album("MPREb_x"))
        #expect(try route(#"{"browseEndpoint":{"browseId":"VLPLx"}}"#) == .playlist("PLx"))
        #expect(try route(#"{"browseEndpoint":{"browseId":"UCx"}}"#) == .artist("UCx"))
        #expect(try route(#"{"browseEndpoint":{"browseId":"FEmusic_charts","params":"p"}}"#) == .charts)
        #expect(try route(#"{"browseEndpoint":{"browseId":"FEmusic_moods_and_genres_category","params":"g"}}"#) == .genre("g"))
        #expect(try route(#"{"browseEndpoint":{"browseId":"MPADUCx","params":"d"}}"#) == .browse(id: "MPADUCx", params: "d"))
        #expect(try route(#"{"searchEndpoint":{"query":"daft punk"}}"#) == .search("daft punk"))
        #expect(try route(#"{"watchEndpoint":{"videoId":"v"}}"#) == nil)
    }
}
