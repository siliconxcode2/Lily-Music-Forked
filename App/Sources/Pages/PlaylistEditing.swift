import SwiftUI
import YTMCore

/// The header's rename and delete, which ask first.
enum PlaylistDialog {
    case rename, delete
}

extension EnvironmentValues {
    /// The page of the account's own playlist whose songs the rows are, which their menus remove and dragging
    /// moves; nil anywhere else, its other sections included.
    @Entry var ownPlaylist: PageModel?
}

extension PlaylistPrivacy {
    var title: String {
        switch self {
        case .public: "Public"
        case .unlisted: "Unlisted"
        case .private: "Private"
        }
    }
}

/// Asks before the header's rename and delete; kept on the page, as the header may be built twice to fit.
struct PlaylistDialogs: ViewModifier {
    @Binding var dialog: PlaylistDialog?
    /// The rename's field, which starts from the name as it is.
    @Binding var name: String
    let title: String
    let model: PageModel?

    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content
            .alert("Rename Playlist", isPresented: shown(.rename)) {
                TextField("Name", text: $name)
                    .onSubmit(rename)
                Button("Cancel", role: .cancel) {}
                Button("Save", action: rename)
            }
            .alert("Delete Playlist", isPresented: shown(.delete)) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    if let model { app.deletePlaylist(in: model) }
                }
            } message: {
                Text("Delete \u{201C}\(title)\u{201D}? This can't be undone.")
            }
    }

    private func shown(_ which: PlaylistDialog) -> Binding<Bool> {
        Binding(get: { dialog == which }, set: { if !$0, dialog == which { dialog = nil } })
    }

    private func rename() {
        if let model { app.renamePlaylist(in: model, to: name) }
    }
}

/// A song of the account's own playlist, dragged onto another, moves there: system drag and drop, which leaves the
/// long press to the row's menu until the finger moves. A line marks where it lands, under the song it is dropped on
/// when dragged down and over it when dragged up.
struct EntryDrag: ViewModifier {
    let track: Track
    let index: Int

    @Environment(AppModel.self) private var app
    @Environment(\.ownPlaylist) private var model
    @Environment(\.theme) private var theme
    @State private var targeted = false

    func body(content: Content) -> some View {
        if let model, let entry = track.setVideoId {
            content
                .onDrag {
                    model.dragged = entry
                    return NSItemProvider(object: entry as NSString)
                }
                .dropDestination(for: String.self) { entries, _ in
                    model.dragged = nil
                    // Text dragged in from elsewhere is no song of the page.
                    guard let dropped = entries.first, model.page?.headerTracks.contains(where: { $0.setVideoId == dropped }) == true
                    else { return false }
                    app.moveInPlaylist(dropped, to: index, in: model)
                    return true
                } isTargeted: { targeted = $0 }
                .overlay {
                    if targeted, let edge = lineEdge(model) {
                        theme.accent.frame(height: 2).frame(maxHeight: .infinity, alignment: edge).accessibilityHidden(true)
                    }
                }
        } else {
            content
        }
    }

    /// Nil over the song dragged, which stays where it is.
    private func lineEdge(_ model: PageModel) -> Alignment? {
        guard let from = model.page?.headerTracks.firstIndex(where: { $0.setVideoId == model.dragged }), from != index
        else { return nil }
        return from < index ? .bottom : .top
    }
}
