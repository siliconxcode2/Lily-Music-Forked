import CoreGraphics
import YTMCore

nonisolated struct ArtworkColours: Equatable, Sendable {
    /// Nil for greyish artwork, whose hue means nothing.
    let vivid: RGB?
    /// `ArtworkPalette.meshEdge` squared, row by row from the top.
    let mesh: [RGB]

    @concurrent
    static func of(_ image: CGImage) async -> ArtworkColours {
        let (accent, mesh) = ArtworkPalette.colours(image)
        return ArtworkColours(vivid: ArtworkPalette.vivid(accent), mesh: mesh)
    }

    /// Nil when the artwork can't be had.
    static func of(url: String, pixelEdge: Int) async -> ArtworkColours? {
        guard let image = await image(url, pixelEdge: pixelEdge) else { return nil }
        return await of(image)
    }

    /// Only the background, without Now Playing's grid.
    @concurrent
    static func background(url: String, pixelEdge: Int) async -> RGB? {
        await image(url, pixelEdge: pixelEdge).map(ArtworkPalette.accent)
    }

    private static func image(_ url: String, pixelEdge: Int) async -> CGImage? {
        let image = await ImagePipeline.shared.image(for: url, pixelEdge: pixelEdge)
        return Task.isCancelled ? nil : image
    }
}
