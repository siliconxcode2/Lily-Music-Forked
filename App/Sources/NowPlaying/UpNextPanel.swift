import SwiftUI
import YTMCore
import YTMPlayback

/// Rows, the selection and each row's actions follow queue entries by ID,
/// not place, so an open swipe or menu acts on its own song however the
/// queue moves.
struct UpNextPanel: View {
    /// Off screen, the list keeps the song playing at its top, ready for the
    /// swipe up.
    let isShown: Bool
    /// Beside the player, under the list rather than over it.
    let actionsBelow: Bool
    /// For a pull down past the top of the list.
    let close: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var editMode = EditMode.inactive
    @State private var selection = Set<Queue<Track>.Entry.ID>()

    var body: some View {
        let queue = app.player.queue
        VStack(spacing: 0) {
            if actionsBelow {
                // Only the list fades, so the actions under it stay clear.
                list(queue).mask(SidePanel.fade)
                header(count: queue.count)
            } else {
                header(count: queue.count)
                list(queue)
            }
        }
        // Picks stay with their entries through an edit; a new queue, whose
        // entries are all new, lets them go.
        .onChange(of: queue.revision) {
            guard !selection.isEmpty else { return }
            selection.formIntersection(app.player.queue.entries.lazy.map(\.id))
        }
    }

    private var editing: Bool { editMode.isEditing }

    private func header(count: Int) -> some View {
        HStack(spacing: 14) {
            Text(editing && !selection.isEmpty ? "\(selection.count) selected" : "Queue  •  \(Formatting.songs(count))")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Spacer()
            if editing {
                Group {
                    PanelAction(title: "Play next") { app.player.playNext(queueOffsets: offsets(selection)) }
                    PanelAction(title: "Remove") { app.player.removeFromQueue(atOffsets: offsets(selection)) }
                }
                .disabled(selection.isEmpty)
                IconButton(icon: .close, size: 28, iconSize: 16) { stopSelecting() }
                    .accessibilityLabel("Done selecting")
            } else {
                if app.isSignedIn {
                    PanelAction(title: "Save") { app.saveQueueAsPlaylist() }
                }
                if count > 1 {
                    PanelAction(title: "Select") { editMode = .active }
                    PanelAction(title: "Clear") { app.player.clearUpcoming() }
                }
            }
        }
        .frame(height: 44)
        .padding(.horizontal, NowPlayingScreen.padding)
        .animation(Theme.fast, value: editing)
    }

    private func list(_ queue: Queue<Track>) -> some View {
        let currentId = queue.currentIndex.map { queue.entries[$0].id }
        return ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(queue.entries) { entry in
                    row(entry, current: entry.id == currentId)
                }
                .onMove { app.player.moveQueue(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, Theme.queueRow)
            .environment(\.editMode, $editMode)
            .onScrollPhaseChange { old, new, context in
                if pulledPastTop(old, new, context.geometry) { close() }
            }
            .onAppear {
                if let currentId { proxy.scrollTo(currentId, anchor: .top) }
            }
            // Off screen, back to the song playing whenever it changes or the panel goes.
            .onChange(of: isShown ? nil : currentId) { _, id in
                if let id { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    private func row(_ entry: Queue<Track>.Entry, current: Bool) -> some View {
        Button {
            if let index = offsets([entry.id]).first { app.player.jump(to: index) }
        } label: {
            QueueRow(track: entry.item, current: current, recommended: entry.isRecommended)
        }
        .buttonStyle(RowPress())
        // While selecting, a tap picks the row, which the list does.
        .allowsHitTesting(!editing)
        // Inset so the artwork lines up with the header, inside its own 8 points.
        .listRowInsets(EdgeInsets(top: 0, leading: NowPlayingScreen.padding - 8, bottom: 0, trailing: NowPlayingScreen.padding - 8))
        .listRowBackground(selection.contains(entry.id) ? theme.hover : Color.clear)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing) {
            if !current {
                Button("Remove", role: .destructive) { app.player.removeFromQueue(atOffsets: offsets([entry.id])) }
            }
        }
        .contextMenu {
            Button("Play next") { app.player.playNext(queueOffsets: offsets([entry.id])) }
                .disabled(current)
            Button("Remove from queue") { app.player.removeFromQueue(atOffsets: offsets([entry.id])) }
                .disabled(current)
            TrackDownloadItem(track: entry.item)
            Button("Copy link") { app.copyLink(entry.item.link) }
            TrackLibraryMenu(track: entry.item)
        }
    }

    /// Where the entries `ids` sit now, worked out only as an action runs;
    /// none for entries gone meanwhile.
    private func offsets(_ ids: Set<Queue<Track>.Entry.ID>) -> IndexSet {
        let entries = app.player.queue.entries
        return IndexSet(entries.indices.filter { ids.contains(entries[$0].id) })
    }

    private func stopSelecting() {
        editMode = .inactive
        selection.removeAll()
    }
}

private struct PanelAction: View {
    let title: String
    let action: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isEnabled ? theme.textSecondary : theme.textDim)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.95))
    }
}
