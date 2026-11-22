import SwiftUI

struct HistoryScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.isSignedIn && app.settings.value.youtubeHistory {
            PageScreen(route: .history)
        } else {
            LocalHistoryScreen()
        }
    }
}

private struct LocalHistoryScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let page = app.history.page {
            PageContent(page: page, route: .history)
        } else {
            PageStatus(phase: .empty("Songs you play will show up here."), tint: Theme.routeTint(.history))
        }
    }
}
