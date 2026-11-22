import Foundation
import Testing
@testable import YTMCore

/// A `next` response trimmed to its queue panel and tabs: a song, a music
/// video, a wrapped song signed-in radios send, and an item without an ID.
private let next = #"""
{"contents":{"singleColumnMusicWatchNextResultsRenderer":{"tabbedRenderer":{"watchNextTabbedResultsRenderer":{"tabs":[
  {"tabRenderer":{"content":{"musicQueueRenderer":{"content":{"playlistPanelRenderer":{"contents":[
    {"playlistPanelVideoRenderer":{"videoId":"pRIZohFFOMo","title":{"runs":[{"text":"Someone You Loved"}]},
      "longBylineText":{"runs":[
        {"text":"Lewis Capaldi","navigationEndpoint":{"browseEndpoint":{"browseId":"UCl","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}}}},
        {"text":" • "},
        {"text":"Divinely Uninspired","navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_d","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}}}},
        {"text":" • "},{"text":"2019"}]},
      "lengthText":{"runs":[{"text":"3:03"}]},
      "thumbnail":{"thumbnails":[{"url":"https://lh3.googleusercontent.com/s=w60-h60","width":60,"height":60}]},
      "navigationEndpoint":{"watchEndpoint":{"videoId":"pRIZohFFOMo","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_ATV"}}}}}},
    {"playlistPanelVideoRenderer":{"videoId":"yPYZpwSpKmA","title":{"runs":[{"text":"Together Forever"}]},
      "longBylineText":{"runs":[{"text":"Rick Astley","navigationEndpoint":{"browseEndpoint":{"browseId":"UCr","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}}}},
        {"text":" • "},{"text":"208M views"}]},
      "lengthText":{"runs":[{"text":"3:24"}]},
      "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/yPYZpwSpKmA/sddefault.jpg","width":640,"height":480}]}}},
    {"playlistPanelVideoWrapperRenderer":{"primaryRenderer":{"playlistPanelVideoRenderer":{"videoId":"a8dzSKRtctU",
      "title":{"runs":[{"text":"Smalltown Boy"}]},"longBylineText":{"runs":[{"text":"Bronski Beat"},{"text":" & "},{"text":"Friends"}]},
      "thumbnail":{"thumbnails":[{"url":"https://lh3.googleusercontent.com/b=w60-h60","width":60,"height":60}]}}}}},
    {"playlistPanelVideoRenderer":{"title":{"runs":[{"text":"No ID"}]}}},
    {"automixPreviewVideoRenderer":{}}
  ]}}}}}},
  {"tabRenderer":{"endpoint":{"browseEndpoint":{"browseId":"MPLYt_lyrics","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_TRACK_LYRICS"}}}}}},
  {"tabRenderer":{"endpoint":{"browseEndpoint":{"browseId":"MPTRt_related","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_TRACK_RELATED"}}}}}}
]}}}}}
"""#

@Suite struct RadioTests {
    @Test func readsTheQueuePanel() throws {
        let tracks = try Renderers.queue(in: JSON(data: Data(next.utf8)))
        #expect(tracks.map(\.id) == ["pRIZohFFOMo", "yPYZpwSpKmA", "a8dzSKRtctU"])

        let song = tracks[0]
        #expect(song.title == "Someone You Loved")
        #expect(song.artists == [ArtistRef(id: "UCl", name: "Lewis Capaldi")])
        #expect(song.album == AlbumRef(id: "MPREb_d", name: "Divinely Uninspired"))
        #expect(song.duration == 183)
        #expect(song.thumbnail == "https://lh3.googleusercontent.com/s=w120-h120-l90-rj")
        #expect(!song.isVideo)

        let video = tracks[1]
        #expect(video.isVideo, "told by its wide thumbnail")
        #expect(video.album == nil, "a video's second part is its views")
        #expect(video.artistNames == "Rick Astley")

        let wrapped = tracks[2]
        #expect(wrapped.artists.map(\.name) == ["Bronski Beat", "Friends"], "unlinked artists without the separator")
        #expect(!wrapped.isVideo)
        #expect(wrapped.duration == nil)
    }

    @Test func noQueueIsNoRadio() throws {
        #expect(throws: YTMError.self) { try Renderers.queue(in: JSON(data: Data("{}".utf8))) }
    }

    @Test func findsTheLyricsTab() throws {
        #expect(Lyrics.browseId(in: try JSON(data: Data(next.utf8))) == "MPLYt_lyrics")
        #expect(Lyrics.browseId(in: try JSON(data: Data("{}".utf8))) == nil)
    }
}
