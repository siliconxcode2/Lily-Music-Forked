import CoreGraphics

/// Sized for a 6.3" portrait screen; wider ones, as iPhone Duo's inner
/// display is, fit more columns rather than larger cards.
nonisolated enum Metrics {
    /// A 393 pt screen can't spare the desktop's 24 on both sides.
    static let pagePadding: CGFloat = 16
    /// Space under a page's last row, clear of the tab bar's edge.
    static let pageBottom: CGFloat = 24

    static let rowHeight: CGFloat = 56
    static let rowPadding: CGFloat = 8
    static let rowSpacing: CGFloat = 12
    static let rowArt: CGFloat = 40
    static let rowNumber: CGFloat = 24
    static let rowMore: CGFloat = 28
    static let rowDuration: CGFloat = 44

    static let titleHeight: CGFloat = 68
    static let greetingHeight: CGFloat = 48
    static let columnsHeight: CGFloat = 44

    // On a phone there is no hover background, so the artwork takes the card's
    // whole width and the gap between cards does the spacing.
    /// The desktop's 188 would fit a single grid column on a phone.
    static let cardWidth: CGFloat = 156
    static let cardGap: CGFloat = 12
    static let cardArtRadius: CGFloat = 6

    static let chipMinWidth: CGFloat = 150
    static let chipHeight: CGFloat = 96
    static let chipGap: CGFloat = 12

    static let headerArt: CGFloat = 232
    static let bannerHeight: CGFloat = 300
    static let actionsHeight: CGFloat = 88
    static let topResultArt: CGFloat = 96
    static let topResultHeight: CGFloat = 200

    static let tintHeight: CGFloat = 420
    /// How far the header scrolls away before its title shows in the bar.
    static let stickyTitleAfter: CGFloat = 280

    static func cardColumns(width: CGFloat) -> (count: Int, cell: CGFloat) {
        columns(width: width, minimum: cardWidth, gap: cardGap)
    }

    static func chipColumns(width: CGFloat) -> (count: Int, cell: CGFloat) {
        columns(width: width, minimum: chipMinWidth, gap: chipGap)
    }

    private static func columns(width: CGFloat, minimum: CGFloat, gap: CGFloat) -> (count: Int, cell: CGFloat) {
        let count = max(1, Int(((width + gap) / (minimum + gap)).rounded(.down)))
        return (count, max(0, (width - CGFloat(count - 1) * gap) / CGFloat(count)))
    }
}
