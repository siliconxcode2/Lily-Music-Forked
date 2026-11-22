import SwiftUI
import YTMCore

struct SectionHeader: View {
    let title: String
    let more: Route?

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title2.weight(.heavy))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            if let more {
                PillButton(title: "More", small: true) { app.open(more) }
            }
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.top, 28)
        .padding(.bottom, 12)
        .frame(minHeight: Metrics.titleHeight, alignment: .bottom)
    }
}
