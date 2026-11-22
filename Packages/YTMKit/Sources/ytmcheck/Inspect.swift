import Foundation
import YTMCore

/// `search <q>` and `page <route>`: a page printed in full.
enum Inspect {
    static func route(_ text: String) -> Route? {
        switch text.lowercased() {
        case "home": return .home
        case "explore": return .explore
        case "charts": return .charts
        case "new-releases", "newreleases": return .newReleases
        case "moods", "moods-and-genres", "moodsandgenres": return .moodsAndGenres
        default: break
        }
        let parts = text.split(separator: ":", maxSplits: 2).map(String.init)
        if parts.count >= 2 {
            switch parts[0] {
            case "album": return .album(parts[1])
            case "artist": return .artist(parts[1])
            case "playlist": return .playlist(parts[1])
            case "genre": return .genre(parts[1])
            case "search": return .search(parts.dropFirst().joined(separator: ":"))
            case "browse": return .browse(id: parts[1], params: parts.count > 2 ? parts[2] : nil)
            default: return nil
            }
        }
        if text.hasPrefix("MPRE") { return .album(text) }
        if text.hasPrefix("UC") { return .artist(text) }
        if text.hasPrefix("VL") { return .playlist(String(text.dropFirst(2))) }
        if ["PL", "RD", "OLAK", "LM"].contains(where: text.hasPrefix) { return .playlist(text) }
        return nil
    }

    static func show(_ route: Route) async throws {
        var page = try await Live.api.page(route)
        while page.more != nil {
            page = try await Live.api.loadMore(page)
        }
        print(describe(page))
    }

    static func describe(_ page: Page) -> String {
        var lines: [String] = []
        if let header = page.header {
            lines.append("[\(header.label)] \(header.title)")
            for (label, value) in [("subtitle", header.subtitle), ("meta", header.meta)] where !value.isEmpty {
                lines.append("  \(label): \(value)")
            }
            if let description = header.description {
                lines.append("  description: \(description.prefix(100).replacing("\n", with: " "))…")
            }
            lines.append("  art: \(artwork(header.thumbnail))\(header.banner ? " banner" : "")")
            for (label, value) in [("radio", header.radioId), ("playlist", header.playlistId), ("shuffle", header.shufflePlaylistId)] {
                if let value { lines.append("  \(label): \(value)") }
            }
        }
        for section in page.sections {
            switch section {
            case .tracks(let s):
                lines.append("\n== \(s.title.isEmpty ? "(tracks)" : s.title): \(s.tracks.count) tracks, \(s.mode)\(s.numbered ? ", numbered" : "")\(more(s.more))")
                lines += s.tracks.prefix(itemsShown).map(describe)
                if s.tracks.count > itemsShown { lines.append("   …and \(s.tracks.count - itemsShown) more") }
            case .cards(let s):
                lines.append("\n== \(s.title): \(s.cards.count) cards, \(s.layout)\(more(s.more))")
                lines += s.cards.prefix(itemsShown).map(describe)
                if s.cards.count > itemsShown { lines.append("   …and \(s.cards.count - itemsShown) more") }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ track: Track) -> String {
        let number = track.trackNumber.map { String(format: "%3d. ", $0) } ?? "   - "
        let details = [
            track.artists.map { $0.name + ($0.id == nil ? "*" : "") }.joined(separator: ", "),
            track.album?.name,
            track.duration.map(Formatting.duration),
        ].compactMap { $0?.isEmpty == false ? $0 : nil }
        return "\(number)\(track.title) — \(details.joined(separator: " · "))  [\(track.id)]"
            + (track.isVideo ? " VIDEO" : "") + "  \(artwork(track.thumbnail))"
    }

    static func describe(_ card: Card) -> String {
        let colour = card.color.map { String(format: " #%06X", $0) } ?? ""
        return "   [\(card.kind)] \(card.title) — \(card.subtitle)  [\(card.id.prefix(40))]\(colour)  \(artwork(card.thumbnail))"
    }

    /// The host and asked size only, never the whole URL.
    static func artwork(_ url: String?) -> String {
        guard let url else { return "no art" }
        guard let parsed = URL(string: url), let host = parsed.host() else { return "bad art URL" }
        let size = url.range(of: #"=w\d+-h\d+"#, options: .regularExpression).map { String(url[$0].dropFirst()) }
            ?? parsed.lastPathComponent
        return "\(host) \(size)"
    }

    private static let itemsShown = 30

    private static func more(_ route: Route?) -> String {
        route.map { ", more → \($0)" } ?? ""
    }
}
