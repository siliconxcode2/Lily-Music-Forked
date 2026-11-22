import SwiftUI

struct ToastView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let toast = app.toast {
                HStack(spacing: 12) {
                    // A petal of the icon's gradient.
                    RoundedRectangle(cornerRadius: 2).fill(Theme.lilyGradient).frame(width: 4)
                    Text(toast.message)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.text)
                }
                // Keeps the petal as tall as the text rather than the screen.
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .padding(.trailing, 6)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .frame(maxWidth: 480)
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
                .id(toast.id)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 16)))
            }
        }
        .animation(Theme.normal, value: app.toast)
        // Each toast is felt: a failure as an error, anything else as done.
        .sensoryFeedback(trigger: app.toast) { _, toast in
            guard let toast else { return nil }
            return toast.message.hasPrefix("Couldn") || toast.message.hasPrefix("Can't") ? .error : .success
        }
        .allowsHitTesting(false)
    }
}
