import Foundation
import Testing
@testable import YTMCore

@Suite struct LibraryEditsTests {
    private func json(_ text: String) throws -> JSON {
        try JSON(data: Data(text.utf8))
    }

    @Test func readsTheLikeButtonsState() throws {
        func next(_ status: String) throws -> JSON {
            try json(#"""
                {"playerOverlays":{"playerOverlayRenderer":{"actions":[{"likeButtonRenderer":
                  {"target":{"videoId":"x"},"likeStatus":"\#(status)","likesAllowed":true}}]}}}
                """#)
        }
        #expect(Rating(next: try next("LIKE")) == .like)
        #expect(Rating(next: try next("DISLIKE")) == .dislike)
        #expect(Rating(next: try next("INDIFFERENT")) == .none)
        #expect(Rating(next: try json("{}")) == .none)
    }

    @Test func readsWhetherAnEditSucceeded() throws {
        #expect(YTMusic.succeeded(try json(#"{"status":"STATUS_SUCCEEDED","playlistEditResults":[]}"#)))
        #expect(!YTMusic.succeeded(try json(#"{"status":"STATUS_FAILED"}"#)))
        #expect(!YTMusic.succeeded(try json("{}")))
    }

    @Test func readsWhetherAChangeWasMade() throws {
        #expect(throws: Never.self) { try YTMusic.performed(try json(#"{"responseContext":{},"actions":[{"addToToastAction":{}}]}"#)) }
        #expect(throws: Never.self) { try YTMusic.performed(try json(#"{"responseContext":{}}"#)) }
        let held = try json(#"{"actions":[{"showEngagementPanelEndpoint":{"identifier":{"tag":"x"}}}]}"#)
        #expect(throws: YTMError.self) { try YTMusic.performed(held) }
    }

    @Test func saysWhenSharingAPlaylistNeedsAChannel() throws {
        let asked = try json(#"{"status":"STATUS_FAILED","actions":[{"openPopupAction":{"popup":{"channelCreationFormEndpoint":{}}}}]}"#)
        #expect(YTMusic.playlistRefusal(asked).message == "The account needs a YouTube channel to share playlists.")
        #expect(YTMusic.playlistRefusal(try json(#"{"status":"STATUS_FAILED"}"#)).message == "YouTube didn't change the playlist.")
    }

    @Test func takesOnlyYouTubeIds() throws {
        for id in ["PLaZPMsuQNCsWn0iVMtGbaUXO6z-EdZaZm", "UC0C-w0YjGpqDXGB8IHb662A", "56B44F6D10557CC6"] {
            #expect(try YTMusic.youtubeId(id) == id)
        }
        for id in ["", #"C:\Music\song.mp3"#, #"PL1","x"#, "PL 1", String(repeating: "a", count: 65)] {
            #expect(throws: YTMError.self, "\(id)") { try YTMusic.youtubeId(id) }
        }
        #expect(try YTMusic.videoId("dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        for id in ["", "dQw4w9WgXc", "dQw4w9WgXcQQ", "dQw4w9WgXc/", "PLaZPMsuQNCsWn0iVMtGbaUXO6z-EdZaZm"] {
            #expect(throws: YTMError.self, "\(id)") { try YTMusic.videoId(id) }
        }
    }

    @Test func listsOwnPlaylists() throws {
        let reply = try json(#"""
            {"contents":[{"addToPlaylistRenderer":{"playlists":[
              {"playlistAddToOptionRenderer":{"playlistId":"PL1","title":{"simpleText":"Road trip"},"containsSelectedVideos":"NONE"}},
              {"playlistAddToOptionRenderer":{"playlistId":"PL2","title":{"runs":[{"text":"Gym"}]},"containsSelectedVideos":"ALL"}},
              {"playlistAddToOptionRenderer":{"title":{"simpleText":"No ID"}}}]}}]}
            """#)
        #expect(PlaylistOption.list(in: reply) == [
            PlaylistOption(id: "PL1", title: "Road trip", contains: false),
            PlaylistOption(id: "PL2", title: "Gym", contains: true),
        ])
        #expect(PlaylistOption.list(in: try json("{}")) == nil)
    }
}
