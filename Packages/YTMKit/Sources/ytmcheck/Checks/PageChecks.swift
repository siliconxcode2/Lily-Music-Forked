import Foundation
@testable import YTMCore

enum PageChecks {
    static func run(_ report: Report) async {
        await report.check("page home") { findings in
            let page = try await Live.api.page(.home)
            findings.audit(page, "home", minimumSections: 4)
            findings.titles(page, ["Trending", "New releases", "Top artists", "Browse moods & genres"])
            findings.expect(page.tracks("Trending").count <= 10, "home: more than 10 trending tracks")
            findings.kinds(page.cards("New releases"), .album, "home › New releases")
            findings.kinds(page.cards("Top artists"), .artist, "home › Top artists")
            findings.expect(page.cards("Browse moods & genres").count == 12, "home: not 12 moods & genres chips")
            findings.expect(page.more == nil, "home: signed out, the page is whole")
        }

        await report.check("page explore") { findings in
            let page = try await Live.api.page(.explore)
            findings.audit(page, "explore", minimumSections: 4)
            findings.titles(page, ["Moods & moments", "Genres", "New albums & singles", "New music videos"])
            findings.kinds(page.cards("New albums & singles"), .album, "explore › New albums & singles")
            let videos = page.tracks("New music videos")
            findings.expect(videos.allSatisfy(\.isVideo), "explore › New music videos: not all marked as videos")
            findings.expect(videos.count <= YTMusic.shelfLimit, "explore › New music videos: more than \(YTMusic.shelfLimit)")
        }

        var genre: Card?
        await report.check("page moods & genres") { findings in
            let page = try await Live.api.page(.moodsAndGenres)
            findings.audit(page, "moods & genres", minimumSections: 2)
            findings.titles(page, ["Moods & moments", "Genres"])
            let chips = page.cards("Moods & moments") + page.cards("Genres")
            findings.kinds(chips, .genre, "moods & genres")
            genre = page.cards("Genres").first
            findings.note("\(page.cards("Moods & moments").count) moods, \(page.cards("Genres").count) genres")
        }

        await report.check("page genre") { findings in
            guard let genre else { return findings.fail("no genre to open") }
            let page = try await Live.api.page(.genre(genre.id))
            findings.audit(page, "genre \(genre.title)")
            findings.expect(page.header?.label == "Genre" && page.header?.title == genre.title, "genre: header \(page.header.map { "\($0.label) \($0.title)" } ?? "none")")
            for section in page.sections {
                guard case .cards(let row) = section else { findings.fail("genre: a track section"); continue }
                findings.kinds(row.cards, .playlist, "genre › \(row.title)")
            }
            findings.note("\(genre.title): \(page.sections.map(\.title).joined(separator: ", "))")
        }

        await report.check("page new releases") { findings in
            let page = try await Live.api.page(.newReleases)
            findings.audit(page, "new releases")
            findings.note(page.summary)
        }

        await report.check("page charts") { findings in
            let page = try await Live.api.page(.charts)
            findings.audit(page, "charts")
            findings.kinds(page.cards("Top artists"), .artist, "charts › Top artists")
            findings.note(page.summary)
        }

        await report.check("page search") { findings in
            let page = try await Live.api.page(.search("daft punk"))
            findings.audit(page, "search", minimumSections: 5)
            let order = ["Top result", "Songs", "Videos", "Artists", "Albums", "Playlists"]
            let titles = page.sections.map(\.title)
            findings.expect(titles == order.filter(titles.contains), "search: sections \(titles), wanted in the order \(order)")
            findings.titles(page, ["Songs", "Videos", "Artists", "Albums", "Playlists"])
            if case .cards(let top)? = page.section("Top result") {
                findings.expect(top.layout == .top && top.cards.count == 1, "search › Top result: \(top.cards.count) cards, \(top.layout)")
                findings.expect(top.cards.first?.id == Live.artist, "search › Top result: not Daft Punk")
            }
            findings.expect(page.tracks("Songs").allSatisfy { !$0.isVideo }, "search › Songs: a video among them")
            findings.expect(page.tracks("Videos").allSatisfy(\.isVideo), "search › Videos: not all marked as videos")
            findings.expect(page.tracks("Songs").allSatisfy { $0.album != nil }, "search › Songs: a song without its album")
            findings.kinds(page.cards("Artists"), .artist, "search › Artists")
            findings.kinds(page.cards("Albums"), .album, "search › Albums")
            findings.kinds(page.cards("Playlists"), .playlist, "search › Playlists")
            for title in ["Songs", "Videos", "Artists", "Albums", "Playlists"] {
                if case .tracks(let s)? = page.section(title) { findings.expect(s.mode == .radio && s.more == nil, "search › \(title): \(s.mode), more \(String(describing: s.more))") }
                if case .cards(let s)? = page.section(title) { findings.expect(s.layout == .carousel && s.more == nil, "search › \(title): \(s.layout)") }
            }
        }

        await report.check("search suggestions") { findings in
            let suggestions = await Live.api.suggestions(for: "daft pu")
            findings.expect(suggestions.contains { $0.lowercased() == "daft punk" }, "no \"daft punk\" among \(suggestions)")
            findings.expect(Set(suggestions).count == suggestions.count, "repeated suggestions")
            findings.expect(await Live.api.suggestions(for: "  ").isEmpty, "suggestions for nothing")
            findings.note(suggestions.joined(separator: " | "))
        }
    }
}

extension Findings {
    mutating func titles(_ page: Page, _ titles: [String]) {
        let missing = titles.filter { page.section($0) == nil }
        expect(missing.isEmpty, "missing sections \(missing); has \(page.sections.map(\.title))")
    }

    mutating func kinds(_ cards: [Card], _ kind: CardKind, _ label: String) {
        let others = cards.filter { $0.kind != kind }
        expect(others.isEmpty, "\(label): \(others.count) cards not \(kind), such as \(others.first.map { "\($0.kind) \($0.title)" } ?? "")")
    }
}
