import Foundation
import Testing
@testable import YTMCore

@Suite struct SettingsTests {
    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    @Test func anUnreadableSettingResetsOnlyItself() throws {
        let settings = try decode(#"{"youtubeHistory": false, "accent": "beige", "equaliserGains": [1], "volume": 0.5}"#)
        #expect(!settings.youtubeHistory, "the opt-out is kept")
        #expect(settings.accent == .lily)
        #expect(settings.equaliserGains == Array(repeating: 0, count: 10))
    }

    @Test func sixOldEqualiserBandsCarryOverToTen() throws {
        // 31 Hz holds the old lowest, at 60 Hz; 62 Hz is just past it. 250 Hz is about halfway, in octaves,
        // from 150 to 400 Hz.
        #expect(try decode(#"{"equaliserGains": [1, 2, 3, 4, 5, 6]}"#).equaliserGains == [1, 1, 2, 3, 3, 4, 5, 5, 6, 6])
        #expect(try decode(#"{"equaliserGains": [6, 4, 1, 0, 0, 0]}"#).equaliserGains == [6, 6, 4, 2, 1, 0, 0, 0, 0, 0], "Bass boost")
        #expect(try decode(#"{"equaliserGains": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]}"#).equaliserGains[9] == 10)
        #expect(try decode(#"{"equaliserGains": [-0.4, 0, 0, 0, 0, 0]}"#).equaliserGains[0].sign == .plus, "no -0")
    }

    @Test func fillsMissingFieldsWithDefaults() throws {
        let settings = try decode(#"{"look": "dark", "accent": "artwork", "shuffle": "smart"}"#)
        #expect(settings.look == .dark && settings.accent == .artwork && settings.shuffle == .smart)
        #expect(settings.normalise == .normal && !settings.crossfade && settings.quality == .high)
        #expect(!settings.foldToScrub, "off until asked for")
        #expect(settings.pauseOnUnplug, "on until turned off")
        #expect(!settings.crossfeed && !settings.mono && settings.balance == 0)
        #expect(Settings.crossfadeLengths.contains(settings.crossfadeSeconds), "a length Settings offers")
        let saved = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(Settings.self, from: saved) == settings)
    }

    @Test func readsNormaliseFromOlderVersions() throws {
        #expect(try decode(#"{"normalise": false}"#).normalise == .off)
        #expect(try decode(#"{"normalise": true}"#).normalise == .normal)
        var quiet = Settings()
        quiet.normalise = .quiet
        let saved = try JSONEncoder().encode(quiet)
        #expect(String(decoding: saved, as: UTF8.self).contains(#""normalise":"quiet""#))
        #expect(try JSONDecoder().decode(Settings.self, from: saved).normalise == .quiet, "and its own")
    }

    @Test func keepsTheBalanceWithinTheSides() throws {
        #expect(try decode(#"{"balance": -0.25, "crossfeed": true, "mono": true}"#).balance == -0.25)
        #expect(try decode(#"{"balance": 3}"#).balance == 1)
        #expect(try decode(#"{"balance": -3}"#).balance == -1)
    }

    @Test func keepsOnlyASpeedSettingsOffers() throws {
        #expect(Settings().speed == 1)
        #expect(try decode(#"{"speed": 1.2}"#).speed == 1.2)
        #expect(try decode(#"{"speed": 1.7}"#).speed == 1, "not offered")
    }

    @Test func keepsTheCrossfadeWithinTheLengthsOffered() throws {
        #expect(try decode(#"{"crossfadeSeconds": 10}"#).crossfadeSeconds == 10)
        #expect(try decode(#"{"crossfadeSeconds": 30}"#).crossfadeSeconds == 12)
        #expect(try decode(#"{"crossfadeSeconds": 0.2}"#).crossfadeSeconds == 1)
        #expect(try !decode(#"{"pauseOnUnplug": false}"#).pauseOnUnplug)
    }

    @Test func keepsTheAccountAndPinsAcrossSaves() throws {
        let old = try decode(#"{"look": "dark"}"#)
        #expect(old.account == nil && old.pinned.isEmpty, "none in a file from before they were kept")
        var settings = Settings()
        settings.account = Account(name: "Lily", photo: "https://yt3.ggpht.com/a")
        settings.pinned = ["LM", "PL1"]
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func defaultsToLilysOrchidMatchingTheSystem() {
        let settings = Settings()
        #expect(settings.accent == .lily && settings.look == .system)
        #expect(Accent.allCases.first == .lily, "offered first")
        #expect(Accent.lily.rgb == 0xd65db1)
    }

    @Test func accentsAreLilysColours() {
        #expect(Accent.red.rgb == 0xff0033)
        #expect(Accent.artwork.rgb == nil)
        #expect(Accent.artwork.name == "From the artwork")
    }
}

@Suite struct HistoryTests {
    @Test func keepsTheNewestPlayOfEachSong() {
        var history = PlayHistory()
        for id in ["a", "b", "a"] { history.record(Track(id: id, title: id)) }
        #expect(history.tracks.map(\.id) == ["a", "b"])
        let long = PlayHistory(tracks: (0..<600).map { Track(id: "\($0)", title: "") } + [Track(id: "0", title: "")])
        #expect(long.tracks.count == 500)
    }

    @Test func onlySongsHeardLongEnoughReachSpeedDial() throws {
        var history = PlayHistory()
        history.record(Track(id: "a", title: "a"))
        history.record(Track(id: "b", title: "b"))
        history.markHeard("a")
        #expect(history.heard.map(\.id) == ["a"])
        #expect(history.tracks.count == 2, "both are in the history")
        history.record(Track(id: "a", title: "a"))
        #expect(history.heard.isEmpty, "a skipped replay")
        let saved = try JSONDecoder().decode(PlayHistory.self, from: JSONEncoder().encode(history))
        #expect(saved.skipped == ["a", "b"])
    }

    @Test func aFileFromBeforeSkipsCountsEveryPlayAsHeard() throws {
        let file = try JSONEncoder().encode(["tracks": [Track(id: "a", title: "a")]])
        let old = try JSONDecoder().decode(PlayHistory.self, from: file)
        #expect(old.heard.map(\.id) == ["a"])
    }

    @Test func aSongPushedOutOfTheHistoryLeavesItsSkip() {
        var history = PlayHistory()
        for id in 0...500 { history.record(Track(id: "\(id)", title: "")) }
        #expect(history.tracks.count == 500)
        #expect(!history.skipped.contains("0") && history.skipped.count == 500)
        let trimmed = PlayHistory(tracks: [Track(id: "x", title: "")], skipped: ["x", "gone"])
        #expect(trimmed.skipped == ["x"])
    }

    @Test func searchesKeepTheNewestFiveOnceEach() throws {
        var searches = RecentSearches()
        for q in ["a", "b", "c", "d", "e", "f"] { searches.record(q) }
        #expect(searches.queries == ["f", "e", "d", "c", "b"])
        searches.record("  C ")
        #expect(searches.queries == ["C", "f", "e", "d", "b"])
        searches.record("   ")
        searches.remove("F")
        #expect(searches.queries == ["C", "e", "d", "b"])
        let edited = try JSONDecoder().decode(
            RecentSearches.self, from: Data(#"{"queries":["x","  ","X","y ","a","b","c","d"]}"#.utf8))
        #expect(edited.queries == ["x", "y", "a", "b", "c"], "trimmed, without blanks or repeats, the newest five")
    }
}

@Suite struct FileStoreTests {
    @Test func laterSavesWinAndRemovesDelete() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ytm-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileStore(directory: directory)
        #expect(store.load([String].self, from: .searches) == nil)
        for n in 0..<50 { store.save(["\(n)"], to: .searches) }
        #expect(store.load([String].self, from: .searches) == ["49"])
        store.remove(.searches)
        #expect(store.load([String].self, from: .searches) == nil)
        store.save(Settings(), to: .settings)
        #expect(store.load(Settings.self, from: .settings) == Settings())
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted() == ["settings.json"])
    }
}
