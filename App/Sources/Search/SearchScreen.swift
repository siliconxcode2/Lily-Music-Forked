import SwiftUI
import YTMCore

struct SearchScreen: View {
    private static let suggestDelay: Duration = .milliseconds(150)
    private static let suggestFrom = 2
    private static let suggestionLimit = 8

    @Environment(AppModel.self) private var app
    @State private var query = ""
    /// Typed since focusing the field, so suggestions replace the recent searches.
    @State private var typed = false
    @State private var suggestions: [String] = []
    @State private var shown: String?
    /// Which kind of result shows, as Apple Music's search filters.
    @State private var scope = SearchScope.all

    var body: some View {
        @Bindable var app = app
        // The results stay in the tree under the dropdown, so cancelling a
        // search shows them again in place, scrolled where they were.
        ZStack {
            if let shown {
                PageScreen(route: .search(shown))
                    .id(shown)
                    .environment(\.sectionScope, scope.title)
                    // Covered by the choices while searching, so VoiceOver skips it.
                    .accessibilityHidden(app.isSearching)
            } else {
                SearchPrompt()
            }
            if app.isSearching {
                SearchChoices(
                    choices: showsRecent ? app.history.searches.queries : suggestions,
                    recent: showsRecent,
                    pick: search
                )
            }
        }
        // Always showing, so the query stays in view over its results.
        .searchable(text: $query, isPresented: $app.isSearching, placement: .navigationBarDrawer(displayMode: .always), prompt: "What do you want to play?")
        .onSubmit(of: .search) { search(query) }
        .toolbar {
            if shown != nil, !app.isSearching {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Show", selection: $scope.animation(Theme.normal)) {
                            ForEach(SearchScope.allCases, id: \.self) { scope in
                                Text(scope.title ?? "All Results").tag(scope)
                            }
                        }
                    } label: {
                        Label("Filter", systemImage: scope == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
        }
        .onChange(of: app.isSearching) { _, active in
            // Each focus starts with the recent searches, even over the last query.
            typed = false
            if !active { suggestions = [] }
        }
        .onChange(of: query) {
            if app.isSearching { typed = true }
        }
        .task(id: suggestKey) { await suggest(suggestKey) }
    }

    private var showsRecent: Bool {
        query.isEmpty || !typed
    }

    /// The query to suggest for, or nil when none is wanted; each change
    /// restarts the wait, dropping the request for the last keystroke.
    private var suggestKey: String? {
        guard app.isSearching, !showsRecent else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= Self.suggestFrom ? trimmed : nil
    }

    private func suggest(_ query: String?) async {
        guard let query else {
            suggestions = []
            return
        }
        do {
            try await Task.sleep(for: Self.suggestDelay)
        } catch {
            return
        }
        let found = await app.api.suggestions(for: query)
        guard !Task.isCancelled else { return }
        suggestions = Array(found.prefix(Self.suggestionLimit))
    }

    private func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        app.isSearching = false
        query = trimmed
        app.history.recordSearch(trimmed)
        app.navigation(for: .search).routes.removeAll()
        scope = .all
        shown = trimmed
    }
}

private struct SearchChoices: View {
    let choices: [String]
    let recent: Bool
    let pick: (String) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        List {
            ForEach(choices, id: \.self) { choice in
                HStack(spacing: 14) {
                    Button { pick(choice) } label: {
                        HStack(spacing: 14) {
                            IconView(icon: recent ? .history : .search, size: 18, colour: theme.textSecondary)
                            Text(choice)
                                .font(.subheadline)
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if recent {
                        IconButton(icon: .close, iconSize: 16) { app.history.removeSearch(choice) }
                            .accessibilityLabel("Remove \u{201C}\(choice)\u{201D}")
                    }
                }
                .listRowBackground(theme.panel)
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing) {
                    if recent {
                        Button(role: .destructive) { app.history.removeSearch(choice) } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.panel)
        .scrollDismissesKeyboard(.immediately)
    }
}

private struct SearchPrompt: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ContentUnavailableView(
            "What do you want to play?",
            systemImage: "magnifyingglass",
            description: Text("Search for songs, albums, artists and playlists.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.panel)
    }
}

/// The kinds of result search can narrow to, titled as their sections are.
private enum SearchScope: CaseIterable {
    case all, songs, videos, artists, albums, playlists

    /// The section kept; nil keeps them all.
    var title: String? {
        switch self {
        case .all: nil
        case .songs: "Songs"
        case .videos: "Videos"
        case .artists: "Artists"
        case .albums: "Albums"
        case .playlists: "Playlists"
        }
    }
}
