import SwiftUI

/// iOS's own activity indicator, in a `size`-point square: large from 36 points, regular below.
struct Spinner: View {
    let size: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(size >= 36 ? .large : .regular)
            .tint(theme.text)
            .frame(width: size, height: size)
            .accessibilityLabel("Loading")
    }
}
