import CoreGraphics

/// A colour in sRGB, each channel 0...1.
public struct RGB: Codable, Hashable, Sendable {
    public var r, g, b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// From `0xRRGGBB`.
    public init(hex: UInt32) {
        self.init(
            r: Double(hex >> 16 & 0xFF) / 255, g: Double(hex >> 8 & 0xFF) / 255, b: Double(hex & 0xFF) / 255
        )
    }
}

/// Colours taken from artwork, each made readable in each look.
public enum ArtworkPalette {
    /// The least saturation `accent` gives, which greyish artwork gets.
    private static let minSaturation = 0.25
    /// How much colour, summed over the 256 pixels sampled, makes a hue
    /// worth following: a few strong pixels, or a faint wash over a tenth.
    private static let colourfulWeight = 2.0
    /// Hue pools, so artwork of several colours gives its strongest one
    /// rather than their average, which tends to grey.
    private static let hues = 12
    private static let sampleEdge = 16
    public static let meshEdge = 4

    private struct Pool {
        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0, chroma = 0.0
    }

    /// The `accent`, and a `meshEdge`-square grid of the artwork's colours
    /// row by row from the top, for Now Playing's background.
    public static func colours(_ image: CGImage) -> (accent: RGB, mesh: [RGB]) {
        let pixels = sample(image)
        return (accent(pixels), mesh(pixels))
    }

    /// The artwork's strongest colour, darkened enough for white text.
    public static func accent(_ image: CGImage) -> RGB {
        accent(sample(image))
    }

    private static func accent(_ pixels: [RGB]) -> RGB {
        var pools = [Pool](repeating: Pool(), count: hues)
        for pixel in pixels {
            let (h, s, l) = hsl(pixel)
            // Saturated mid-tones count; greys, black and white hardly do.
            let chroma = s * (1 - abs(2 * l - 1))
            // Cubed, so a vivid area outweighs a larger dull one: a sky over
            // beige buildings is blue, not beige.
            let weight = chroma * chroma * chroma
            // Offset half a pool, so red, which sits at 0° and 360°, and the
            // other primaries fall in the middle of one rather than across two.
            let index = Int(h / 360 * Double(hues) + 0.5) % hues
            pools[index].r += pixel.r * weight
            pools[index].g += pixel.g * weight
            pools[index].b += pixel.b * weight
            pools[index].weight += weight
            pools[index].chroma += chroma
        }
        let best = pools.reduce(Pool()) { $1.weight >= $0.weight ? $1 : $0 }
        let mean = best.weight > 0
            ? RGB(r: best.r / best.weight, g: best.g / best.weight, b: best.b / best.weight)
            : RGB(r: 0, g: 0, b: 0)
        let (h, s, _) = hsl(mean)
        // Muted artwork with one hue stays above greyish artwork's floor, so
        // `vivid` can tell them apart. Chroma, unlike saturation, stays low
        // for near-black with a cast.
        let chroma = max(mean.r, mean.g, mean.b) - min(mean.r, mean.g, mean.b)
        let saturation = chroma >= 0.05 && best.chroma >= colourfulWeight
            ? min(max(s, minSaturation + 0.1), 0.7)
            : minSaturation
        // Bright hues such as yellow are darkened further to keep white text
        // at 4.5:1.
        return readable(fromHSL(h, saturation, 0.32), light: true)
    }

    /// Each cell's mean, no more colourful than the area and within the
    /// accent's band of lightness, so white text reads across them all.
    private static func mesh(_ pixels: [RGB]) -> [RGB] {
        let block = sampleEdge / meshEdge
        let count = Double(block * block)
        return (0..<meshEdge * meshEdge).map { cell in
            let (row, column) = cell.quotientAndRemainder(dividingBy: meshEdge)
            var (r, g, b) = (0.0, 0.0, 0.0)
            for y in row * block..<(row + 1) * block {
                for pixel in pixels[(y * sampleEdge + column * block)..<(y * sampleEdge + (column + 1) * block)] {
                    r += pixel.r
                    g += pixel.g
                    b += pixel.b
                }
            }
            let mean = RGB(r: r / count, g: g / count, b: b / count)
            let (h, _, l) = hsl(mean)
            // Chroma rather than saturation, which runs high for near-black
            // with a cast.
            let chroma = max(mean.r, mean.g, mean.b) - min(mean.r, mean.g, mean.b)
            return readable(rgb(h, min(chroma * 1.5, 0.8), 0.25 + l * 0.1), light: true)
        }
    }

    /// A saturated take on an `accent`, for controls drawn in it rather than
    /// backgrounds behind white text, or nil when it is greyish.
    public static func vivid(_ accent: RGB) -> RGB? {
        let (h, s, _) = hsl(accent)
        // A little above the floor, as the colour went through 8-bit channels.
        return s > minSaturation + 0.05 ? fromHSL(h, max(s, 0.5), 0.5) : nil
    }

    /// `colour` made just light or dark enough to read as text on the look's
    /// background, and in the dark looks behind white icons (WCAG 4.5:1, 3:1).
    public static func readable(_ colour: RGB, look: Look) -> RGB {
        readable(colour, light: look == .light)
    }

    static func readable(_ colour: RGB, light: Bool) -> RGB {
        let range = light ? 0.0...0.18 : 0.175...0.3
        let lum = luminance(colour)
        if range.contains(lum) { return colour }
        // A little inside the range, which rounding to 8-bit channels could
        // otherwise step out of.
        let target = lum > range.upperBound ? range.upperBound - 0.01 : range.lowerBound + 0.01
        // Luminance rises with lightness, so halve the range towards the target.
        let (h, s, _) = hsl(colour)
        var (low, high) = (0.0, 1.0)
        for _ in 0..<20 {
            let mid = (low + high) / 2
            if luminance(rgb(h, s, mid)) < target { low = mid } else { high = mid }
        }
        return fromHSL(h, s, (low + high) / 2)
    }

    /// WCAG's relative luminance.
    static func luminance(_ colour: RGB) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(colour.r) + 0.7152 * linear(colour.g) + 0.0722 * linear(colour.b)
    }

    /// The centre square of `image` scaled to 16 × 16 in sRGB, black where
    /// it can't be drawn.
    private static func sample(_ image: CGImage) -> [RGB] {
        let edge = sampleEdge
        var bytes = [UInt8](repeating: 0, count: edge * edge * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress, width: edge, height: edge, bitsPerComponent: 8,
                      bytesPerRow: edge * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                  )
            else { return }
            // Averages each area rather than picking single pixels.
            context.interpolationQuality = .high
            // The centre square, as the artwork views crop to fill, so a video's
            // wide thumbnail gives the colours shown rather than its edges'.
            let scale = Double(edge) / Double(min(image.width, image.height))
            let width = Double(image.width) * scale
            let height = Double(image.height) * scale
            context.draw(image, in: CGRect(x: (Double(edge) - width) / 2, y: (Double(edge) - height) / 2, width: width, height: height))
        }
        return stride(from: 0, to: bytes.count, by: 4).map {
            RGB(r: Double(bytes[$0]) / 255, g: Double(bytes[$0 + 1]) / 255, b: Double(bytes[$0 + 2]) / 255)
        }
    }

    /// Rounded through 8-bit channels, which `vivid`'s threshold allows for.
    static func fromHSL(_ h: Double, _ s: Double, _ l: Double) -> RGB {
        func byte(_ c: Double) -> Double { min(max((c * 255).rounded(), 0), 255) / 255 }
        let colour = rgb(h, s, l)
        return RGB(r: byte(colour.r), g: byte(colour.g), b: byte(colour.b))
    }

    static func hsl(_ colour: RGB) -> (h: Double, s: Double, l: Double) {
        let (r, g, b) = (colour.r, colour.g, colour.b)
        let high = max(r, g, b)
        let low = min(r, g, b)
        let l = (high + low) / 2
        let d = high - low
        if d < 1e-6 { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        let h = if high == r {
            ((g - b) / d).euclideanRemainder(6)
        } else if high == g {
            (b - r) / d + 2
        } else {
            (r - g) / d + 4
        }
        return (h * 60, s, l)
    }

    static func rgb(_ h: Double, _ s: Double, _ l: Double) -> RGB {
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h / 60).euclideanRemainder(2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double) = switch Int(h / 60) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        return RGB(r: r + m, g: g + m, b: b + m)
    }
}

private extension Double {
    func euclideanRemainder(_ divisor: Double) -> Double {
        let remainder = truncatingRemainder(dividingBy: divisor)
        return remainder < 0 ? remainder + divisor : remainder
    }
}
