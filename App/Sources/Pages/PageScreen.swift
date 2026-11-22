import SwiftUI
import YTMCore

/// Builds its model in its own body, not the parent's, so what building it reads (the account, and
/// the history for Home) never re-runs the tab tree or Search.
struct PageScreen: View {
    let route: Route

    @Environment(AppModel.self) private var app

    var body: some View {
        PageBody(route: route, app: app)
    }
}

private struct PageBody: View {
    let route: Route

    @State private var model: PageModel
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    /// The app went to the background with the page on screen, so the next
    /// visit is a return to the app rather than to the page.
    @State private var backgrounded = false

    /// A new account or a return from the background, as Home may have aged;
    /// Control Centre and the like leave the app in the foreground.
    private struct Visit: Hashable {
        let account: Int
        let foreground: Bool
    }

    init(route: Route, app: AppModel) {
        self.route = route
        _model = State(initialValue: PageModel(route: route, app: app))
    }

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                PageStatus(phase: .loading(route), tint: Theme.routeTint(route))
            case .failed(let message):
                PageStatus(phase: .failed(message: message) {
                    Task { await model.retry(in: app) }
                }, tint: Theme.routeTint(route))
            case .loaded(let page):
                PageContent(page: page, route: route, model: model)
                    // No rise: it lands over a skeleton of its shape.
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: model.page != nil)
        .task(id: Visit(account: app.accountGeneration, foreground: scenePhase != .background)) {
            guard scenePhase != .background else {
                backgrounded = true
                return
            }
            let returning = backgrounded
            backgrounded = false
            await model.appear(in: app, returning: returning)
        }
        // Completes the page while it is on screen, so Home is saved whole.
        .task(id: model.step) { await model.loadMore(in: app) }
        // Read only on Library's pages, the ones pins reorder and a saved queue joins.
        .onChange(of: route.showsPins ? app.pinned : []) { model.rearrange(in: app) }
        .onChange(of: route.showsPins ? app.playlistsAdded : 0) { model.adoptCached(in: app) }
    }
}
