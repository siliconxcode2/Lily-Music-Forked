import SwiftUI
import YTMCore

/// Views take their colours from here, never literals.
nonisolated struct Theme: Equatable, Sendable {
    /// Lily's orchid, the accent when nothing else gives one.
    static let lily = RGB(hex: 0xd65db1)
    /// The icon's orchid-to-violet gradient, as its artwork runs it.
    static let lilyGradient = LinearGradient(
        stops: [
            .init(color: Color(rgb: RGB(hex: 0xf472d0)), location: 0.2),
            .init(color: Color(rgb: RGB(hex: 0x9b5cff)), location: 0.8),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let panelRadius: CGFloat = 8
    /// Every queue row is this tall, so a dragged row's place is arithmetic.
    static let queueRow: CGFloat = 60
    static let fast = Animation.easeOut(duration: 0.12)
    static let normal = Animation.easeOut(duration: 0.22)

    let look: Look
    /// The accent, already made readable in the look.
    let accent: Color

    let panel: Color
    let elevated: Color
    let highlight: Color
    let menu: Color
    /// What translucent washes over the surfaces are made of.
    let ink: Color
    let hover: Color
    let divider: Color

    let text: Color
    let textSecondary: Color
    let textDim: Color
    /// Text on a fill of `text`'s colour, such as a primary button.
    let textInverse: Color
    /// Text and icons on the accent, artwork and other strong colours: white in every look.
    let onColour = Color(rgb: .white)

    let shadowSoft = Color(rgb: .black).opacity(0.376)
    let shadow = Color(rgb: .black).opacity(0.5)
    let shadowDeep = Color(rgb: .black).opacity(0.565)
    /// Darkens the foot of an artist's banner behind its white text.
    let bannerShade = Color(rgb: .black).opacity(0.69)

    /// Behind Home, a dark take on the accent; Lily's orchid gives #4d2140.
    private let homeTint: RGB

    /// The surfaces and text are iOS's own adaptive colours, so they match the
    /// system's bars, sheets and glass; the colour scheme the look sets picks
    /// their light or dark take. Black is iOS's own dark; Dark sits a step up from it.
    init(look: Look, accent: RGB) {
        let dark = look == .dark
        func system(_ colour: UIColor) -> Color { Color(uiColor: colour) }
        self.look = look
        self.accent = Color(rgb: accent)
        panel = system(dark ? .secondarySystemBackground : .systemBackground)
        elevated = system(dark ? .tertiarySystemBackground : .secondarySystemBackground)
        highlight = system(dark ? .systemGray4 : .systemGray5)
        menu = system(look == .light ? .systemBackground : dark ? .tertiarySystemBackground : .secondarySystemBackground)
        ink = Color(rgb: look == .light ? .black : .white)
        hover = system(.tertiarySystemFill)
        divider = system(.separator)
        text = system(.label)
        textSecondary = system(.secondaryLabel)
        textDim = system(.tertiaryLabel)
        textInverse = system(.systemBackground)
        homeTint = accent.mixed(with: .black, weight: 0.36)
    }

    /// `artworkAccent` is the playing artwork's vivid colour, for the accent that follows it. The System look
    /// is Black or Light as `systemDark` says.
    init(settings: Settings, artworkAccent: RGB?, systemDark: Bool) {
        let follows = settings.look == .system
        let look = follows ? (systemDark ? Look.black : .light) : settings.look
        let accent = settings.accent.rgb.map(RGB.init(hex:)) ?? artworkAccent ?? Self.lily
        self.init(look: look, accent: ArtworkPalette.readable(accent, look: look))
        followsSystem = follows
    }

    /// Set by the System look, which leaves iOS to choose light or dark.
    private(set) var followsSystem = false

    var isLight: Bool { look == .light }
    /// Nil when following iOS, so its own appearance shows through.
    var colorScheme: ColorScheme? {
        followsSystem ? nil : isLight ? .light : .dark
    }

    /// A colour picked for behind white text, such as an artwork's, paled in
    /// the light look so dark text reads on it.
    func tint(_ colour: RGB) -> Color {
        Color(rgb: isLight ? colour.mixed(with: .white, weight: 0.3) : colour)
    }

    func pageTint(_ colour: RGB?) -> Color {
        tint(colour ?? homeTint)
    }

    /// The tint of a page without artwork; nil for Home, whose tint follows the accent.
    static func routeTint(_ route: Route) -> RGB? {
        switch route {
        case .home: nil
        case .explore: RGB(hex: 0x1e3264)
        case .library: RGB(hex: 0x3d1f5c)
        case .search: RGB(hex: 0x2a2a2a)
        default: RGB(hex: 0x333333)
        }
    }
}

extension EnvironmentValues {
    @Entry var theme = Theme(look: .black, accent: Theme.lily)
}

nonisolated extension RGB {
    static let white = RGB(r: 1, g: 1, b: 1)
    static let black = RGB(r: 0, g: 0, b: 0)

    /// `weight` of this colour, the rest of `other`.
    func mixed(with other: RGB, weight: Double) -> RGB {
        RGB(r: r * weight + other.r * (1 - weight), g: g * weight + other.g * (1 - weight), b: b * weight + other.b * (1 - weight))
    }

    /// The HSV value divided by 1 + `factor`, which scales every sRGB channel alike.
    func darker(_ factor: Double) -> RGB {
        RGB(r: r / (1 + factor), g: g / (1 + factor), b: b / (1 + factor))
    }
}

nonisolated extension Color {
    init(rgb: RGB) {
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}
