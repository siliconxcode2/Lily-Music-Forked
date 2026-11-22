import Foundation
@testable import YTMCore

extension Findings {
    mutating func audit(_ page: Page, _ label: String, minimumSections: Int = 1) {
        expect(page.sections.count >= minimumSections, "\(label): \(page.sections.count) sections, wanted \(minimumSections)+")
        if let header = page.header {
            expect(!header.title.isEmpty, "\(label): the header has no title")
            if let art = header.thumbnail {
                artwork(art, edge: header.banner ? nil : Thumbnail.header, "\(label) header")
            }
        }
        for section in page.sections {
            let name = "\(label) › \(section.title.isEmpty ? "tracks" : section.title)"
            switch section {
            case .tracks(let s):
                audit(s.tracks, name)
                if s.numbered { numbering(s.tracks, name) }
            case .cards(let s):
                audit(s.cards, name)
            }
        }
    }

    mutating func audit(_ tracks: [Track], _ label: String) {
        expect(!tracks.isEmpty, "\(label): no tracks")
        duplicates(tracks.map(\.id), label)
        for track in tracks {
            let name = "\(label) › \(track.title.isEmpty ? track.id : track.title)"
            expect((try? YTMusic.videoId(track.id)) != nil, "\(name): video ID \(track.id) isn't one")
            expect(!track.title.isEmpty, "\(name): no title")
            expect(!track.artists.isEmpty, "\(name): no artists")
            expect(track.artists.allSatisfy { !$0.name.isEmpty }, "\(name): an artist without a name")
            expect(track.duration.map { $0 > 0 } ?? true, "\(name): length \(track.duration ?? 0)")
            if let art = track.thumbnail {
                artwork(art, edge: Thumbnail.row, name)
            } else {
                fail("\(name): no artwork")
            }
        }
    }

    mutating func audit(_ cards: [Card], _ label: String) {
        expect(!cards.isEmpty, "\(label): no cards")
        duplicates(cards.map(\.id), label)
        for card in cards {
            let name = "\(label) › \(card.title.isEmpty ? card.id : card.title)"
            expect(!card.id.isEmpty, "\(name): no ID")
            expect(!card.title.trimmed.isEmpty, "\(name): no title")
            switch card.kind {
            case .genre:
                expect(card.color != nil, "\(name): a genre without its colour")
            case .song:
                expect(card.track?.id == card.id, "\(name): a song card without its track")
                fallthrough
            case .album, .playlist, .artist:
                expect(!card.subtitle.isEmpty, "\(name): no subtitle")
                if let art = card.thumbnail {
                    artwork(art, edge: Thumbnail.card, name)
                } else {
                    fail("\(name): no artwork")
                }
            }
            switch card.kind {
            case .album: expect(card.id.hasPrefix("MPRE"), "\(name): album ID \(card.id)")
            case .artist: expect(card.id.hasPrefix("UC"), "\(name): artist ID \(card.id)")
            case .playlist, .genre, .song: break
            }
        }
    }

    mutating func numbering(_ tracks: [Track], _ label: String) {
        let numbers = tracks.map(\.trackNumber)
        expect(numbers == tracks.indices.map { $0 + 1 }, "\(label): track numbers \(numbers.map { $0.map(String.init) ?? "-" })")
    }

    /// `edge` is the pixel size googleusercontent art is asked at; nil for banners.
    mutating func artwork(_ url: String, edge: Int?, _ label: String) {
        guard let parsed = URL(string: url), HTTP.isAllowed(parsed) else {
            fail("\(label): artwork on a host the app refuses")
            return
        }
        if let edge, url.contains("googleusercontent.com"), url.contains("=w") {
            expect(url.hasSuffix("=w\(edge)-h\(edge)-l90-rj"), "\(label): artwork not at \(edge) px (\(Inspect.artwork(url)))")
        }
    }

    mutating func duplicates(_ ids: [String], _ label: String) {
        var seen = Set<String>()
        let repeated = ids.filter { !seen.insert($0).inserted }
        expect(repeated.isEmpty, "\(label): repeated \(Set(repeated).sorted().prefix(5))")
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Page {
    func section(_ title: String) -> Section? {
        sections.first { $0.title == title }
    }

    func tracks(_ title: String) -> [Track] {
        guard case .tracks(let s)? = section(title) else { return [] }
        return s.tracks
    }

    func cards(_ title: String) -> [Card] {
        guard case .cards(let s)? = section(title) else { return [] }
        return s.cards
    }

    var summary: String {
        sections.map { section in
            let count = switch section {
            case .tracks(let s): s.tracks.count
            case .cards(let s): s.cards.count
            }
            return "\(section.title.isEmpty ? "(untitled)" : section.title) (\(count))"
        }.joined(separator: ", ")
    }
}
