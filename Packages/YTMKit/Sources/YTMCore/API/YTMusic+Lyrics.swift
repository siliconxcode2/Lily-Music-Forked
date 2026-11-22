import Foundation

extension YTMusic {
    /// Timed lines as the Android app is given them, else the web client's
    /// block of text. Nil when the song has none.
    @concurrent
    public func lyrics(videoId: String) async throws -> Lyrics? {
        let next = try await innerTube.next(["videoId": videoId], authenticated: false)
        guard let browseId = Lyrics.browseId(in: next) else { return nil }
        do {
            // Not retried: the web lyrics are the fallback.
            let android = try await innerTube.post(
                "browse", body: ["browseId": browseId], client: .androidMusic, authenticated: false, retries: 0
            )
            if let timed = Lyrics(timed: android) { return timed }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The web client's lyrics follow, which are the same words.
        }
        return try Lyrics(plain: await innerTube.browse(browseId, authenticated: false))
    }
}

extension Lyrics {
    /// The Lyrics tab's browse ID, which a song without lyrics leaves out.
    static func browseId(in next: JSON) -> String? {
        Renderers.watchNextTabs(next).lazy.compactMap { tab -> String? in
            let endpoint = tab["endpoint"]
            guard Renderers.pageType(endpoint) == "MUSIC_PAGE_TYPE_TRACK_LYRICS" else { return nil }
            return endpoint["browseEndpoint", "browseId"].string
        }.first
    }

    /// Nil when the answer isn't in the shape expected or has no lines.
    /// Synced only if every line has its time.
    init?(timed response: JSON) {
        let data = response["contents", "elementRenderer", "newElement", "type", "componentType", "model", "timedLyricsModel", "lyricsData"]
        let timed = data["timedLyricsData"].array
        guard !timed.isEmpty else { return nil }
        var lines: [String] = []
        var starts: [Double] = []
        lines.reserveCapacity(timed.count)
        starts.reserveCapacity(timed.count)
        for line in timed {
            guard let text = line["lyricLine"].string else { return nil }
            lines.append(text)
            if let ms = line["cueRange", "startTimeMilliseconds"].string.flatMap({ UInt64($0) }) {
                starts.append(Double(ms) / 1000)
            }
        }
        self.init(lines: lines, starts: starts.count == lines.count ? starts : [], source: data["sourceMessage"].string ?? "")
    }

    /// Nil when YouTube answers with a message, such as "Lyrics not
    /// available", instead.
    init?(plain response: JSON) throws {
        let contents = response["contents"]
        if contents["messageRenderer"].exists { return nil }
        guard let shelf = contents["sectionListRenderer", "contents"].array.lazy
            .map({ $0["musicDescriptionShelfRenderer"] }).first(where: \.exists),
            let body = shelf["description"].text
        else { throw YTMError(.parse, "YouTube's lyrics couldn't be read.") }
        self.init(lines: Self.lines(body), source: shelf["footer"].text ?? "")
    }

    /// Keeps the blank lines between verses; `\r\n` is one break, and a
    /// final break ends the last line rather than starting an empty one.
    static func lines(_ body: String) -> [String] {
        var lines = body.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }.map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}
