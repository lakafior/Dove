import AppKit
import DoveAppCore
import DoveKit
import SwiftUI

/// The Watchlist: movies and series saved to follow, with what is new for each (episodes aired, a release date, "In
/// library"). A table, like the Library's Files: Return or a double-click opens the title (its library page when it is
/// held, else its sources), ⌫ removes. The iPhone's list.
struct MacWatchlistView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router
    @State private var path = NavigationPath()
    @State private var selection = Set<Watchlist.Entry.ID>()

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: MediaSummary.self) { MacTitleView(media: $0) }
        }
    }

    private var entries: [Watchlist.Entry] { model.watchlist.list.entries }

    @ViewBuilder
    private var content: some View {
        let titles = model.library.titles
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "Nothing saved yet", systemImage: "bookmark",
                    description: Text("Click the bookmark on a movie or series, or right-click a search result.")
                )
            } else {
                Table(entries, selection: $selection) {
                    TableColumn("Title") { entry in
                        HStack(spacing: 10) {
                            CachedImage(url: entry.media.poster) { Rectangle().fill(.quaternary) }
                                .frame(width: 30, height: 45)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(entry.media.name).lineLimit(1)
                        }
                    }
                    .width(min: 220, ideal: 360)
                    TableColumn("Kind") { entry in Text(entry.media.type == .movie ? "Movie" : "Series") }
                        .width(min: 60, ideal: 80)
                    TableColumn("Year") { entry in Text(entry.media.releaseInfo ?? "–") }
                        .width(min: 50, ideal: 70)
                    TableColumn("Status") { entry in
                        if let status = model.watchlist.status(of: entry, using: model) {
                            Text(status.label())
                                .foregroundStyle(status.announcement != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        }
                    }
                    .width(min: 160, ideal: 280)
                    TableColumn("In library") { entry in
                        if Watchlist.title(for: entry, in: titles) != nil {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    .width(min: 60, ideal: 80)
                }
                .contextMenu(forSelectionType: Watchlist.Entry.ID.self) { ids in
                    let chosen = entries.filter { ids.contains($0.id) }
                    if let first = chosen.first {
                        Button("Open", systemImage: "arrow.up.forward.square") { open(first) }
                        Divider()
                        Button(chosen.count > 1 ? "Remove \(chosen.count) from Watchlist" : "Remove from Watchlist",
                               systemImage: "bookmark.slash") {
                            chosen.forEach { model.watchlist.remove($0) }
                        }
                    }
                } primaryAction: { ids in
                    if let first = entries.first(where: { ids.contains($0.id) }) { open(first) }
                }
                .onDeleteCommand { remove(selection) }
                .onCommand(#selector(NSResponder.selectAll(_:))) { selection = Set(entries.map(\.id)) }
                .takesFocusWhenSelected(selection)
                .focusedSceneValue(\.pageCommands, MacPageCommands(
                    remove: selection.isEmpty ? nil : { remove(selection) },
                    open: selection.isEmpty ? nil : { entries.first { selection.contains($0.id) }.map(open) }
                ))
            }
        }
        .navigationTitle("Watchlist")
        .navigationSubtitle(entries.isEmpty ? "" : "\(entries.count) saved")
        .toolbar {
            let held = model.watchlist.moviesInLibrary(titles)
            if held > 0 {
                ToolbarItem(placement: .primaryAction) {
                    Menu("More", systemImage: "ellipsis.circle") {
                        Button("Remove \(held) movie\(held == 1 ? "" : "s") in your library", systemImage: "checkmark.circle") {
                            model.watchlist.removeMoviesInLibrary(titles)
                        }
                    }
                }
            }
        }
    }

    private func open(_ entry: Watchlist.Entry) {
        if let held = Watchlist.title(for: entry, in: model.library.titles) {
            router.openLibrary(.title(held))
        } else {
            path.append(entry.media)
        }
    }

    private func remove(_ ids: Set<Watchlist.Entry.ID>) {
        for entry in entries where ids.contains(entry.id) { model.watchlist.remove(entry) }
        selection = []
    }
}
