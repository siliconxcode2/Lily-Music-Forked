import SwiftUI
import YTMCore

struct PlaylistPickerSheet: View {
    let track: Track

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var playlists: [PlaylistOption]?
    @State private var naming = false
    @State private var title = ""

    private static let rowHeight: CGFloat = 48

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.menu)
                .navigationTitle("Save to playlist")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                            .tint(theme.text)
                    }
                }
                .alert("New playlist", isPresented: $naming) {
                    TextField("Title", text: $title)
                    Button("Cancel", role: .cancel) {}
                    Button("Create", action: create)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if !app.isSignedIn {
            VStack(spacing: 20) {
                Text("Sign in to save songs to your playlists.")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                PillButton(title: "Sign in", primary: true) { app.sheet = .signIn }
            }
            .padding(24)
        } else if let playlists {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    row("New playlist", new: true) { naming = true }
                    ForEach(playlists) { playlist in
                        row(playlist.title, ticked: playlist.contains) { add(to: playlist) }
                    }
                    if playlists.isEmpty {
                        Text("You have no playlists of your own yet.")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.textSecondary)
                            .padding(12)
                    }
                }
                .padding(.horizontal, 12)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<6, id: \.self) { index in
                    Bone(width: Bone.length(index), height: 12)
                        .padding(.horizontal, 12)
                        .frame(height: Self.rowHeight)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .skeleton()
        }
    }

    private func row(_ title: String, new: Bool = false, ticked: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if new {
                    IconView(icon: .add, size: 20, colour: theme.text)
                }
                Text(title)
                    .font(.system(size: 14, weight: new ? .semibold : .regular))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if ticked {
                    IconView(icon: .check, size: 18, colour: theme.textSecondary)
                        .accessibilityLabel("Has this song")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPress())
    }

    private func load() async {
        guard app.isSignedIn else { return }
        do {
            playlists = try await app.api.playlists(adding: track.id)
        } catch let error where !Task.isCancelled {
            app.showToast("Couldn't load your playlists: \(sentence(for: error))")
            dismiss()
        } catch {
            // Closed while loading.
        }
    }

    private func add(to playlist: PlaylistOption) {
        dismiss()
        guard !playlist.contains else {
            app.showToast("Already in \u{201C}\(playlist.title)\u{201D}")
            return
        }
        save(to: playlist.title) { [app, id = track.id] in
            try await app.api.addToPlaylist(playlist.id, videoIds: [id])
            // Shown afresh, with the song, when next opened.
            app.forget(.playlist(playlist.id))
        }
    }

    private func create() {
        let title = title.trimmingCharacters(in: .whitespaces)
        dismiss()
        save(to: title) { [app, id = track.id] in
            _ = try await app.api.createPlaylist(title: title, videoIds: [id])
            app.forget(.library)
            app.forget(.libraryPlaylists)
        }
    }

    /// Runs a save past the sheet's closing, then says how it went.
    private func save(to title: String, _ work: @escaping () async throws -> Void) {
        let app = app
        Task {
            do {
                try await work()
                app.showToast("Saved to \u{201C}\(title)\u{201D}")
            } catch {
                app.showToast("Couldn't save to \u{201C}\(title)\u{201D}: \(sentence(for: error))")
            }
        }
    }
}
