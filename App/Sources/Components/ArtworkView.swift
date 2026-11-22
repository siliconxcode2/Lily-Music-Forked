import SwiftUI
import YTMCore

struct ArtworkView: View {
    let url: String?
    let size: CGFloat
    var round = false
    var radius: CGFloat = 4
    /// For sharing a decode made elsewhere rather than one at the size drawn.
    var pixelEdge: Int?
    /// Cast by a shape behind the opaque artwork, so the blur comes from a path once instead of
    /// being rendered off screen each frame the image fades in or resizes.
    var shadow: (colour: Color, radius: CGFloat, y: CGFloat)?

    @Environment(\.theme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: round ? size / 2 : radius)
        ArtworkImage(url: url, edge: size, pixelEdge: pixelEdge)
            .frame(width: size, height: size)
            .background(theme.highlight)
            .clipShape(shape)
            .background {
                if let shadow {
                    shape.fill(theme.highlight).shadow(color: shadow.colour, radius: shadow.radius, y: shadow.y)
                }
            }
    }
}

/// Small artwork shares one decode, `ImagePipeline.smallEdge`, so a song's rows and mini player reuse
/// it. An image already in memory shows on the first frame, so scrolling back never flickers.
struct ArtworkImage: View {
    let url: String?
    /// The shorter side drawn, in points: what the decode is sized to.
    let edge: CGFloat
    var placeholder = true
    var pixelEdge: Int?

    @Environment(\.displayScale) private var displayScale
    @Environment(\.theme) private var theme
    @State private var loaded: Loaded?

    private struct Key: Hashable {
        let url: String
        let pixels: Int
    }

    private struct Loaded {
        let key: Key
        let image: CGImage
    }

    var body: some View {
        let key = url.map { Key(url: $0, pixels: pixels) }
        ZStack {
            if let key, let image = image(for: key) {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if placeholder {
                IconView(icon: .note, size: edge * 0.38, colour: theme.textDim)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: key) { await load(key) }
        // A lazy list can keep its rows' state once scrolled past, so a long one would hold every row's art beyond
        // the memory cache's budget; shown again, the cache's copy draws on the first frame.
        .onDisappear { loaded = nil }
    }

    private var pixels: Int {
        pixelEdge ?? Self.pixels(edge: edge, scale: displayScale)
    }

    /// Shared so a prefetch asks for the very decode the view will.
    static func pixels(edge: CGFloat, scale: CGFloat) -> Int {
        max(Int((edge * scale).rounded(.up)), ImagePipeline.smallEdge)
    }

    /// Until the load has run, a copy already in memory at any size stands in.
    private func image(for key: Key) -> CGImage? {
        if let loaded, loaded.key == key { return loaded.image }
        return Self.cachedAnySize(key.url, preferring: key.pixels, scale: displayScale)
    }

    /// `pixels` first, then every size the app draws, so opening a card's page or playing it never
    /// waits on a download for art already decoded at another size.
    static func cachedAnySize(_ url: String, preferring pixels: Int? = nil, scale: CGFloat) -> CGImage? {
        let edges = [
            pixels, ImagePipeline.playerEdge, Self.pixels(edge: Metrics.headerArt, scale: scale),
            CardView.artPixels(scale: scale), ImagePipeline.smallEdge,
        ]
        return edges.lazy.compactMap { $0 }
            .compactMap { ImagePipeline.shared.cachedImage(for: url, pixelEdge: $0) }
            .first
    }

    private func load(_ key: Key?) async {
        guard let key, loaded?.key != key else { return }
        if let image = ImagePipeline.shared.cachedImage(for: key.url, pixelEdge: key.pixels) {
            loaded = Loaded(key: key, image: image)
            return
        }
        let start = ContinuousClock.now
        guard let image = await ImagePipeline.shared.image(for: key.url, pixelEdge: key.pixels), !Task.isCancelled else {
            return
        }
        let next = Loaded(key: key, image: image)
        // A disk-cache hit lands within a frame or two; fading it in reads as a reload, so only a slow fetch fades.
        if ContinuousClock.now - start < .milliseconds(120) {
            loaded = next
        } else {
            withAnimation(.easeOut(duration: 0.3)) { loaded = next }
        }
    }
}
