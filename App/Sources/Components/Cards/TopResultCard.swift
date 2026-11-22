import SwiftUI
import YTMCore

struct TopResultCard: View {
    let card: Card

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Button { app.activate(card, displayScale: displayScale) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ArtworkView(
                    url: card.thumbnail, size: Metrics.topResultArt, round: card.kind == .artist, radius: Metrics.cardArtRadius,
                    shadow: (theme.shadow, 8, 0)
                )
                Spacer(minLength: 16)
                Text(card.title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(theme.text)
                    .minimumScaleFactor(0.7)
                Text(card.subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.top, 4)
                    .padding(.trailing, 72)
            }
            .lineLimit(1)
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: Metrics.topResultHeight, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.elevated))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(PressScale(scale: 0.98))
        .overlay(alignment: .bottomTrailing) {
            PlayButton(size: 52) { app.play(card) }
                .padding(20)
        }
        .contextMenu { CardMenu(card: card) }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.top, 12)
    }
}
