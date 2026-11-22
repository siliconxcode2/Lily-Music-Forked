import Foundation
import Testing
@testable import YTMCore

private func json(_ text: String) throws -> JSON {
    try JSON(data: Data(text.utf8))
}

private let editablePlaylist = #"""
{"contents":{"twoColumnBrowseResultsRenderer":{
  "tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[
    {"musicEditablePlaylistDetailHeaderRenderer":{"editHeader":{"musicPlaylistEditHeaderRenderer":{"privacy":"PRIVATE"}},
      "header":{"musicResponsiveHeaderRenderer":{
      "title":{"runs":[{"text":"Road trip"}]},
      "secondSubtitle":{"runs":[{"text":"1.2K views"},{"text":" • "},{"text":"1,204 songs"},{"text":" • "},{"text":"70+ hours"}]},
      "description":{"musicDescriptionShelfRenderer":{"description":{"runs":[{"text":"For the car"}]}}},
      "facepile":{"avatarStackViewModel":{"text":{"content":"Alex"},"rendererContext":{"commandContext":{"onTap":{"innertubeCommand":{
        "browseEndpoint":{"browseId":"UCalex","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_USER_CHANNEL"}}}}}}}}},
      "thumbnail":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://lh3.googleusercontent.com/p=w544-h544","width":544}]}}}}}}}
  ]}}}}],
  "secondaryContents":{"sectionListRenderer":{"contents":[
    {"musicPlaylistShelfRenderer":{"contents":[
      {"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"v1","playlistSetVideoId":"S1"},
        "flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"One"}]}}},
          {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Band","navigationEndpoint":{"browseEndpoint":{"browseId":"UCband"}}}]}}}],
        "fixedColumns":[{"musicResponsiveListItemFixedColumnRenderer":{"text":{"runs":[{"text":"3:00"}]}}}]}},
      {"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"NEXT"}}}}
    ]}}
  ]}}}}}
"""#

@Suite struct PlaylistPageTests {
    @Test func readsAnOwnedPlaylistsHeaderAndFirstBatch() throws {
        let page = try Renderers.playlistPage(try json(editablePlaylist), id: "PLroad")
        let header = try #require(page.header)
        #expect(header.title == "Road trip" && header.label == "Playlist" && header.subtitle == "Alex")
        #expect(header.meta == "1204 songs • 3 min", "the whole list's count, the loaded tracks' length")
        #expect(header.description == "For the car")
        #expect(header.radioId == "RDAMPLPLroad" && header.playlistId == "PLroad")
        #expect(header.thumbnail == "https://lh3.googleusercontent.com/p=w544-h544-l90-rj")
        #expect(page.more == .tracks(token: "NEXT", seen: ["S1"], fetched: 1))
        let tracks = page.headerTracks
        #expect(tracks.count == 1 && tracks[0].artistNames == "Band")
        #expect(header.editable == true && header.privacy == .private && header.count == 1204)
        #expect(header.saved == nil, "own playlists have no save button")
        #expect(tracks[0].setVideoId == "S1")
    }

    @Test func keepsEntryIdsOnlyFromOwnPlaylists() throws {
        // Liked music and the mixes come in the editable wrapper too, but take no edits.
        let liked = try Renderers.playlistPage(try json(editablePlaylist), id: "LM")
        #expect(liked.header?.editable == nil && liked.header?.privacy == nil)
        #expect(liked.headerTracks.allSatisfy { $0.setVideoId == nil })
        let other = editablePlaylist.replacingOccurrences(of: "musicEditablePlaylistDetailHeaderRenderer", with: "unwrapped")
        let shared = try Renderers.playlistPage(try json(other), id: "PLroad")
        #expect(shared.header?.editable == nil && shared.headerTracks.allSatisfy { $0.setVideoId == nil })
        // Saved queues and history never carry it.
        let own = try Renderers.playlistPage(try json(editablePlaylist), id: "PLroad").headerTracks[0]
        #expect(!String(decoding: try JSONEncoder().encode(own), as: UTF8.self).contains("S1"))
    }

    @Test func readsAnOwnPlaylistsTitleRunsAndOddPrivacy() throws {
        let page = try Renderers.playlistPage(try json(#"""
            {"contents":{"twoColumnBrowseResultsRenderer":{
              "tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[
                {"musicEditablePlaylistDetailHeaderRenderer":{"editHeader":{"musicPlaylistEditHeaderRenderer":{"privacy":"SOMETIMES"}},
                  "header":{"musicResponsiveHeaderRenderer":{"title":{"runs":[{"text":"03 Jan "},{"text":"12:09"}]}}}}}]}}}}]}}}
            """#), id: "PLaZPMsuQNCsWn0iVMtGbaUXO6z-EdZaZm")
        #expect(page.header?.title == "03 Jan 12:09")
        #expect(page.header?.editable == true && page.header?.privacy == nil, "an odd privacy still leaves it editable")
    }

    @Test func readsLibraryStateFromHeaderButtons() throws {
        func saved(_ buttons: String) throws -> Bool? {
            Renderers.saved(try json(#"{"title":{"runs":[{"text":"Revival"}]},"buttons":\#(buttons)}"#))
        }
        #expect(try saved(libraryToggle(toggled: false, "LIKE", "INDIFFERENT")) == false)
        #expect(try saved(libraryToggle(toggled: true, "LIKE", "INDIFFERENT")) == true)
        #expect(try saved(libraryToggle(toggled: false, "INDIFFERENT", "LIKE")) == true)
        // Signed out, the button only asks to sign in.
        #expect(try saved(#"[{"toggleButtonRenderer":{"isToggled":false,"defaultNavigationEndpoint":{"modalEndpoint":{"modal":{}}}}}]"#) == nil)
    }

    @Test func entryIdsFollowInLaterBatchesOfEitherShape() throws {
        let row = #"""
            {"musicResponsiveListItemRenderer":{"playlistItemData":{"playlistSetVideoId":"56B44F6D10557CC6","videoId":"3_R4ulvg8OY"},
              "flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"I Hate Everything"}]}}}]}}
            """#
        for response in [
            #"{"continuationContents":{"musicPlaylistShelfContinuation":{"contents":[\#(row)]}}}"#,
            #"{"onResponseReceivedActions":[{"appendContinuationItemsAction":{"continuationItems":[\#(row)]}}]}"#,
        ] {
            let items = Renderers.continuationItems(in: try json(response)).items
            #expect(Renderers.tracks(items, context: ItemContext(entries: true)).map(\.setVideoId) == ["56B44F6D10557CC6"])
            #expect(Renderers.tracks(items).map(\.setVideoId) == [nil])
        }
    }

    @Test func countsTracksFromEitherSubtitleShape() throws {
        let three = try json(#"{"secondSubtitle":{"runs":[{"text":"6.2M views"},{"text":" • "},{"text":"492 tracks"},{"text":" • "},{"text":"30 hours"}]}}"#)
        let two = try json(#"{"secondSubtitle":{"runs":[{"text":"12 songs"},{"text":" • "},{"text":"53 minutes"}]}}"#)
        #expect(Renderers.trackCount(three) == 492)
        #expect(Renderers.trackCount(two) == 12)
        #expect(Renderers.trackCount(.missing) == nil)
    }
}

private let album = #"""
{"microformat":{"microformatDataRenderer":{"urlCanonical":"https://music.youtube.com/playlist?list=OLAKok"}},
 "contents":{"twoColumnBrowseResultsRenderer":{
  "tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[
    {"musicResponsiveHeaderRenderer":{"title":{"runs":[{"text":"OK Computer"}]},
      "subtitle":{"runs":[{"text":"Album"},{"text":" • "},{"text":"1997"}]},
      "straplineTextOne":{"runs":[{"text":"Radiohead","navigationEndpoint":{"browseEndpoint":{"browseId":"UCrh",
        "browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}}}}]},
      "secondSubtitle":{"runs":[{"text":"3 songs"},{"text":" • "},{"text":"12 minutes"}]},
      "thumbnail":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://lh3.googleusercontent.com/c=w60-h60","width":60}]}}}}}
  ]}}}}],
  "secondaryContents":{"sectionListRenderer":{"contents":[
    {"musicShelfRenderer":{"contents":[
      {"musicResponsiveListItemRenderer":{"index":{"runs":[{"text":"1"}]},"playlistItemData":{"videoId":"a1"},
        "flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Airbag",
            "navigationEndpoint":{"watchEndpoint":{"videoId":"a1","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_ATV"}}}}}]}}},
          {"musicResponsiveListItemFlexColumnRenderer":{"text":{}}},
          {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"19M plays"}]}}}],
        "fixedColumns":[{"musicResponsiveListItemFixedColumnRenderer":{"text":{"runs":[{"text":"4:48"}]}}}]}},
      {"musicResponsiveListItemRenderer":{"index":{"runs":[{"text":"0"}]},"playlistItemData":{"videoId":"v2"},
        "flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Karma Police",
            "navigationEndpoint":{"watchEndpoint":{"videoId":"v2","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_OMV"}}}}}]}}},
          {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Guest","navigationEndpoint":{"browseEndpoint":{"browseId":"UCguest"}}}]}}}]}}
    ]}},
    {"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Other versions"}]}}},
      "contents":[{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"OKNOTOK"}]},"subtitle":{"runs":[{"text":"Album"},{"text":" • "},{"text":"Radiohead"}]},
        "navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_ok2","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}}}}}]}},
    {"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Releases for you"}]}}},
      "contents":[{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Other"}]},
        "navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_x","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}}}}}]}}
  ]}}}}}
"""#

/// An album or playlist's save button, which signed-in pages put before the others.
private func libraryToggle(toggled: Bool, _ off: String, _ on: String) -> String {
    func like(_ status: String) -> String {
        #"{"likeEndpoint":{"status":"\#(status)","target":{"playlistId":"OLAK5uy_nMr9h2VlS-2PULNz3M3XVXQj_P3C2bqaY"}}}"#
    }
    return #"[{"toggleButtonRenderer":{"isToggled":\#(toggled),"defaultServiceEndpoint":\#(like(off)),"toggledServiceEndpoint":\#(like(on))}}]"#
}

@Suite struct AlbumPageTests {
    @Test func readsAnAlbum() throws {
        let details = try Renderers.album(try json(album), id: "MPREb_ok")
        #expect(details.type == .album && details.year == 1997 && details.trackCount == 3)
        #expect(details.playlistId == "OLAKok")
        #expect(details.tracks.map(\.trackNumber) == [1, 2], "a track numbered 0 follows on")
        #expect(details.tracks[0].artistNames == "Radiohead", "an empty artists column means the album's, not the plays")
        #expect(details.tracks[1].artistNames == "Guest")
        #expect(details.needsPlaylist)

        let page = details.page
        let header = try #require(page.header)
        #expect(header.label == "Album" && header.subtitle == "Radiohead")
        #expect(header.meta == "1997 • 2 songs • 5 min")
        #expect(header.radioId == "RDAMPLOLAKok" && header.playlistId == "OLAKok")
        guard case .tracks(let list)? = page.sections.first, case .cards(let versions)? = page.sections.last else {
            Issue.record("expected the tracks then other versions")
            return
        }
        #expect(list.numbered && list.title.isEmpty)
        #expect(list.tracks.allSatisfy { $0.thumbnail == "https://lh3.googleusercontent.com/c=w120-h120-l90-rj" && $0.album?.id == "MPREb_ok" })
        #expect(page.sections.count == 2, "only other versions follow the tracks")
        #expect(versions.title == "Other versions" && versions.cards.map(\.subtitle) == ["Album • Radiohead"])
    }

    @Test func readsASavedAlbumAndFindsItsPlaylistBehindTheButton() throws {
        let toggle = libraryToggle(toggled: true, "LIKE", "INDIFFERENT").dropFirst().dropLast()
        let response = try json(#"""
            {"contents":{"twoColumnBrowseResultsRenderer":{
              "tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[
                {"musicResponsiveHeaderRenderer":{"title":{"runs":[{"text":"Revival"}]},
                  "subtitle":{"runs":[{"text":"Album"},{"text":" • "},{"text":"2017"}]},
                  "buttons":[\#(toggle),{"musicPlayButtonRenderer":{}},
                    {"menuRenderer":{"items":[{"menuNavigationItemRenderer":{"text":{"runs":[{"text":"Shuffle play"}]},
                      "navigationEndpoint":{"watchPlaylistEndpoint":{"playlistId":"OLAK5uy_nMr9h2VlS-2PULNz3M3XVXQj_P3C2bqaY"}}}}]}}]}}]}}}}],
              "secondaryContents":{"sectionListRenderer":{"contents":[{"musicShelfRenderer":{"contents":[]}}]}}}}}
            """#)
        let header = try #require(try Renderers.album(response, id: "MPREb_bHfHGoy7vuv").page.header)
        #expect(header.saved == true)
        #expect(header.playlistId == "OLAK5uy_nMr9h2VlS-2PULNz3M3XVXQj_P3C2bqaY", "the menu is still found behind the save button")
    }

    @Test func adoptsSongsFromTheAlbumsPlaylist() throws {
        var details = try Renderers.album(try json(album), id: "MPREb_ok")
        details.adopt([
            Track(id: "a1", title: "Airbag"),
            Track(id: "song2", title: "Karma Police", duration: 261),
            Track(id: "song3", title: "Lucky"),
        ])
        #expect(details.tracks.map(\.id) == ["a1", "song2", "song3"])
        #expect(!details.tracks[1].isVideo && details.tracks[1].duration == 261)
        #expect(details.tracks[2].trackNumber == 3 && details.tracks[2].album?.name == "OK Computer")
    }
}

private let artist = #"""
{"header":{"musicImmersiveHeaderRenderer":{"title":{"runs":[{"text":"Radiohead"}]},
  "subscriptionButton":{"subscribeButtonRenderer":{"subscriberCountText":{"runs":[{"text":"5.47M"}]}}},
  "startRadioButton":{"buttonRenderer":{"navigationEndpoint":{"watchEndpoint":{"playlistId":"RDEMradio"}}}},
  "shareEndpoint":{"shareEntityEndpoint":{"serializedShareEntity":"GhhVQ3JfaXlVQU5jbjlPWF95eTlwaVlvTHc%3D"}},
  "thumbnail":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[
    {"url":"https://lh3.googleusercontent.com/b=w540-h225","width":540},{"url":"https://lh3.googleusercontent.com/b=w1440-h600","width":1440}]}}}}},
 "contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[
  {"musicCarouselShelfRenderer":{"contents":[{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Radiohead"}]},
    "navigationEndpoint":{"browseEndpoint":{"browseId":"UCchannel","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_USER_CHANNEL"}}}}}}]}},
  {"musicShelfRenderer":{"title":{"runs":[{"text":"Top songs"}]},
    "bottomEndpoint":{"browseEndpoint":{"browseId":"VLOLAKtop","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_PLAYLIST"}}}},
    "contents":[{"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"creep"},
      "flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Creep"}]}}},
        {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Radiohead","navigationEndpoint":{"browseEndpoint":{"browseId":"UCr_iyUANcn9OX_yy9piYoLw"}}}]}}}]}}]}},
  {"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Singles & EPs"}]},
    "moreContentButton":{"buttonRenderer":{"navigationEndpoint":{"browseEndpoint":{"browseId":"MPADUCr","params":"SINGLES"}}}}}},
    "contents":[
      {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Ill Wind"}]},"subtitle":{"runs":[{"text":"2019"}]},
        "navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_ill","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}}}}},
      {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"I Might Be Wrong"}]},"subtitle":{"runs":[{"text":"Album"},{"text":" • "},{"text":"2001"}]},
        "navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_wrong","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}}}}}]}},
  {"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Videos"}]}}},
    "contents":[{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Creep"}]},
      "navigationEndpoint":{"watchEndpoint":{"videoId":"XFk","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_OMV"}}}}}}]}},
  {"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Fans might also like"}]}}},
    "contents":[{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Nirvana"}]},"subtitle":{"runs":[{"text":"60M monthly audience"}]},
      "navigationEndpoint":{"browseEndpoint":{"browseId":"UCnirvana","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}}}}}]}}
 ]}}}}]}}}
"""#

@Suite struct ArtistPageTests {
    @Test func readsTheChannelIdOfAShareEntity() {
        #expect(Renderers.sharedChannelId("GhhVQ3JfaXlVQU5jbjlPWF95eTlwaVlvTHc%3D") == "UCr_iyUANcn9OX_yy9piYoLw")
        #expect(Renderers.sharedChannelId("not base64!") == nil)
    }

    @Test func readsAnArtist() throws {
        let details = try Renderers.artist(try json(artist), id: "UCalias", signedIn: false)
        #expect(details.id == "UCr_iyUANcn9OX_yy9piYoLw", "an alias names the artist's own ID")
        let page = details.page
        let header = try #require(page.header)
        #expect(header.label == "Artist" && header.banner)
        #expect(header.subtitle == "5.5M subscribers")
        #expect(header.radioId == "RDEMradio" && header.shufflePlaylistId == "OLAKtop")
        #expect(header.thumbnail == "https://lh3.googleusercontent.com/b=w1440-h600", "the widest banner, as is")
        #expect(page.sections.map(\.title) == ["Songs", "Albums", "Singles & EPs", "Fans might also like"])
        guard case .tracks(let songs) = page.sections[0], case .cards(let albums) = page.sections[1],
              case .cards(let singles) = page.sections[2]
        else {
            Issue.record("expected songs then releases")
            return
        }
        #expect(songs.more == .playlist("OLAKtop") && songs.tracks.map(\.id) == ["creep", "XFk"], "the videos follow the top songs")
        #expect(songs.tracks.map(\.isVideo) == [false, true])
        #expect(albums.cards.map(\.title) == ["I Might Be Wrong"], "a tile's own label beats its shelf's")
        #expect(singles.cards.map(\.subtitle) == ["Single • Radiohead • 2019"])
        #expect(singles.more == .browse(id: "MPADUCr", params: "SINGLES"))
        #expect(header.subscribed == nil && header.channelId == nil)
    }

    @Test func readsTheSubscriptionOnlyWhenServedSignedIn() throws {
        func artist(subscribed: Bool, signedIn: Bool) throws -> PageHeader? {
            let response = try json(#"""
                {"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[]}}}}]}},
                 "header":{"musicImmersiveHeaderRenderer":{"title":{"runs":[{"text":"Ed Sheeran"}]},
                   "subscriptionButton":{"subscribeButtonRenderer":{"channelId":"UC0C-w0YjGpqDXGB8IHb662A","subscribed":\#(subscribed),
                     "subscriberCountText":{"runs":[{"text":"55.3M"}]}}}}}}
                """#)
            return try Renderers.artist(response, id: "UC0C-w0YjGpqDXGB8IHb662A", signedIn: signedIn).page.header
        }
        let signedIn = try #require(try artist(subscribed: true, signedIn: true))
        #expect(signedIn.subscribed == true && signedIn.channelId == "UC0C-w0YjGpqDXGB8IHb662A")
        #expect(signedIn.subtitle == "55.3M subscribers")
        #expect(try artist(subscribed: false, signedIn: true)?.subscribed == false)
        // Signed out, YouTube says false whatever the account does.
        let signedOut = try artist(subscribed: false, signedIn: false)
        #expect(signedOut?.subscribed == nil && signedOut?.channelId == "UC0C-w0YjGpqDXGB8IHb662A")
    }

    @Test func readsWhetherAnAnswerWasServedSignedOut() throws {
        func answer(_ loggedIn: String) throws -> JSON {
            try json(#"{"responseContext":{"serviceTrackingParams":[{"service":"GFEEDBACK","params":[{"key":"logged_in","value":"\#(loggedIn)"}]}]}}"#)
        }
        #expect(Renderers.answeredSignedOut(try answer("0")))
        #expect(!Renderers.answeredSignedOut(try answer("1")))
        #expect(!Renderers.answeredSignedOut(try json("{}")))
    }
}

@Suite struct SearchAndBrowseTests {
    @Test func readsSuggestedQueries() throws {
        let response = try json(#"""
        {"contents":[{"searchSuggestionsSectionRenderer":{"contents":[
          {"searchSuggestionRenderer":{"suggestion":{"runs":[{"bold":true,"text":"radioh"},{"text":"ead"}]}}},
          {"searchSuggestionRenderer":{"suggestion":{"runs":[{"text":"radiohead creep"}]}}}]}},
         {"searchSuggestionsSectionRenderer":{"contents":[{"musicResponsiveListItemRenderer":{}}]}}]}
        """#)
        #expect(Renderers.suggestions(in: response) == ["radiohead", "radiohead creep"])
    }

    @Test func retitlesWithoutShowAll() {
        let section = Section.tracks(TrackSection(title: "Songs on YouTube", tracks: [], mode: .radio, more: .search("x")))
        guard case .tracks(let retitled) = section.retitled("Songs") else {
            Issue.record("expected a track section")
            return
        }
        #expect(retitled.title == "Songs" && retitled.more == nil)
    }

    @Test func appendsTheItemsOfLaterBatches() throws {
        var section = Section.cards(CardSection(title: "", cards: [], layout: .grid))
        section.append(try json(#"""
        [{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Kid A"}]},"subtitle":{"runs":[{"text":"Album"},{"text":" • "},{"text":"2000"}]},
          "navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_kida","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}}}}},
         {"continuationItemRenderer":{}}]
        """#).array, context: ItemContext(artists: [ArtistRef(id: "UCr", name: "Radiohead")]))
        guard case .cards(let grid) = section else {
            Issue.record("expected a card section")
            return
        }
        #expect(grid.cards.map(\.subtitle) == ["Album • Radiohead • 2000"])
    }
}
