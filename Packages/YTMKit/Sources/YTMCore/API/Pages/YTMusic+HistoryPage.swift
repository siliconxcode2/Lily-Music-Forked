import Foundation

extension YTMusic {
    /// The account's history, so plays on other devices show too; only the
    /// first page YouTube sends.
    @concurrent
    func historyPage() async throws -> Page {
        try await requireSignIn("Sign in to see your YouTube Music history.")
        let tracks = Self.historyTracks(in: try await innerTube.browse("FEmusic_history", params: "oggECgIIAQ%3D%3D"))
        guard let section = Section.tracks("", tracks, mode: .section) else {
            throw YTMError(.notFound, "Songs you play will show up here.")
        }
        // No count: the first page alone wouldn't be the whole history's.
        return Page(header: PageHeader(label: "Recently played", title: "History"), sections: [section])
    }

    /// History comes as one shelf per day.
    static func historyTracks(in response: JSON) -> [Track] {
        Renderers.sectionList(in: response)["contents"].array.flatMap { section in
            Renderers.tracks(section["musicShelfRenderer", "contents"].array)
        }
    }
}
