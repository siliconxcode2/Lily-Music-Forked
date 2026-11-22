import Foundation
import Testing
@testable import YTMCore
@testable import YTMPlayback

struct StreamChooserTests {
    @Test func takesTheAccountAsWithoutPremiumAfterThreeSongsWithout() async throws {
        let music = FakeMusic()
        let chooser = StreamChooser(music: music)
        for id in ["a", "b", "c"] {
            let stream = try await chooser.resolve(videoId: id, wantPremium: true, signedIn: true, quality: .high)
            #expect(!stream.isPremium)
        }
        #expect(chooser.status == .notPremium)
        music.set { $0.calls = [] }
        _ = try await chooser.resolve(videoId: "d", wantPremium: true, signedIn: true, quality: .high)
        #expect(music.calls.first == "stream d", "straight to the free stream")
    }

    @Test func playsPremiumAndCountsIt() async throws {
        let music = FakeMusic()
        music.set { $0.premium["a"] = true }
        let chooser = StreamChooser(music: music)
        let stream = try await chooser.resolve(videoId: "a", wantPremium: true, signedIn: true, quality: .high)
        #expect(stream.isPremium && chooser.status == .premium)
        let free = try await chooser.resolve(videoId: "b", wantPremium: true, signedIn: true, quality: .high)
        #expect(!free.isPremium && !music.calls.contains("stream b"), "a known account takes the web client's best")
    }

    @Test func fallsBackToTheFreeStreamWhenPremiumFails() async throws {
        let music = FakeMusic()
        music.set { $0.premiumFails = true }
        let chooser = StreamChooser(music: music)
        let stream = try await chooser.resolve(videoId: "a", wantPremium: true, signedIn: true, quality: .high)
        #expect(!stream.isPremium && music.calls == ["premium a", "suspect", "stream a"], "the player is checked sooner")
        music.set { $0.calls = [] }
        _ = try await chooser.resolve(videoId: "a", wantPremium: true, signedIn: true, quality: .high, reopening: true)
        #expect(music.calls == ["premium a", "stream a"], "a song opened again after a drop says nothing of Premium")
    }

    @Test func aPlayerThatCantBePreparedIsNotCountedAsAPremiumError() async throws {
        let music = FakeMusic()
        music.set { $0.playerUnprepared = true }
        let chooser = StreamChooser(music: music)
        for id in ["a", "b", "c", "d"] {
            music.set { $0.calls = [] }
            let stream = try await chooser.resolve(videoId: id, wantPremium: true, signedIn: true, quality: .high)
            #expect(!stream.isPremium && music.calls == ["premium \(id)", "stream \(id)"], "no cool-off after three")
        }
    }
}
