import SwiftUI
import YTMCore

struct QualityBadge: View {
    let stream: ResolvedStream

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            if stream.isPremium {
                Text("PREMIUM")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(theme.onColour)
                    .padding(.horizontal, 6)
                    .frame(maxHeight: .infinity)
                    .background(theme.accent)
            }
            Text(stream.badge)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(stream.isPremium ? theme.text : theme.textSecondary)
                .padding(.horizontal, 7)
        }
        .tracking(0.5)
        .frame(height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(stream.isPremium ? theme.accent : theme.ink.opacity(0.19), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
