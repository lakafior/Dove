import AppKit
import DoveAppCore
import DoveKit
import SwiftUI

/// The Library for one sidebar entry (all, or one kind): titles as cover grids, or every item as a sortable table.
/// Title, book and game screens come with phase 3 (`docs/macos.md`); until then cards offer their actions in the
/// context menu.
struct MacLibraryView: View {
    @Environment(AppModel.self) private var model
    let category: LibraryFilter.Category?

    @AppStorage("macLibraryMode") private var mode: Mode = .titles
    @State private var query = ""
    @State private var pendingDelete: [ShelfItem] = []
    @State private var message: String?

    enum Mode: String {
        case titles, files
    }

    private var library: LibraryModel { model.library }

    private var filter: LibraryFilter {
        var filter = LibraryFilter()
        filter.category = category
        filter.query = query
        return filter
    }

    var body: some View {
        Group {
            if library.items.isEmpty {
                emptyState
            } else if mode == .titles {
                MacLibraryTitles(filter: filter, actions: actions)
            } else {
                MacLibraryFiles(items: filter.apply(to: library.items), actions: actions)
            }
        }
        .navigationTitle(category?.title ?? "Library")
        .navigationSubtitle(statusLine)
        .searchable(text: $query, placement: .toolbar, prompt: "Filter")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    Text("Titles").tag(Mode.titles)
                    Text("Files").tag(Mode.files)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await library.refresh(using: model) }
                }
                .keyboardShortcut("r")
                .disabled(library.isLoading)
            }
        }
        .safeAreaInset(edge: .top) {
            if !library.failures.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(library.failures, id: \.self) { Label($0, systemImage: "exclamationmark.triangle") }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.orange.opacity(0.12))
            }
        }
        .confirmationDialog(deleteQuestion, isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
            Button("Delete", role: .destructive) {
                let items = pendingDelete
                Task { await library.delete(items, using: model) }
            }
        } message: {
            Text("They are deleted on the services that hold them.")
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        }
    }

    private var actions: LibraryActions {
        LibraryActions(download: download, reveal: reveal, delete: { pendingDelete = $0 })
    }

    /// Items already on this Mac (iCloud Drive) in the Finder: their files, fetched from iCloud first if needed.
    private func reveal(_ items: [ShelfItem]) {
        Task {
            var files: [URL] = []
            for item in items {
                guard let backend = model.backend(item.item.backend) else { continue }
                do {
                    let full = item.item.files.isEmpty ? try await backend.item(item.item.id) : item.item
                    for file in full.files {
                        if let url = try await backend.downloadRequest(itemID: full.id, fileID: file.id).url { files.append(url) }
                    }
                } catch {
                    message = error.localizedDescription
                }
            }
            if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
        }
    }

    /// Every file of each ready item, to the place its kind goes; what could not start is said at the end.
    private func download(_ items: [ShelfItem]) {
        Task {
            var failures: [String] = []
            for item in items {
                do { try await model.downloadItem(item) } catch { failures.append(error.localizedDescription) }
            }
            if !failures.isEmpty { message = failures.joined(separator: "\n") }
        }
    }

    /// "Updated 2 minutes ago · 46 items, 1.1 TB", like the iPhone's status line.
    private var statusLine: String {
        if library.isLoading { return "Updating…" }
        let usage = LibraryUsage(filter.apply(to: library.items))
        let count = usage.items == 1 ? "1 item" : "\(usage.items) items"
        let size = usage.bytes > 0 ? "\(count), \(usage.bytes.formatted(.byteCount(style: .file)))" : count
        guard let updatedAt = library.updatedAt else { return size }
        return "Updated \(updatedAt.formatted(.relative(presentation: .named))) · \(size)"
    }

    private var deleteQuestion: String {
        pendingDelete.count == 1 ? "Delete \(pendingDelete[0].name)?" : "Delete \(pendingDelete.count) items?"
    }

    @ViewBuilder
    private var emptyState: some View {
        if library.isLoading || !library.hasLoaded {
            ProgressView("Loading the library…")
        } else {
            ContentUnavailableView("Nothing here yet", systemImage: "books.vertical",
                                   description: Text("What you add to your services shows up here."))
        }
    }
}

// MARK: - Titles

/// Cover grids, one per kind, in the iPhone's order: movies, series, books, audiobooks, music, games, other files.
private struct MacLibraryTitles: View {
    @Environment(AppModel.self) private var model
    let filter: LibraryFilter
    let actions: LibraryActions

    private var library: LibraryModel { model.library }

    var body: some View {
        let titles = filter.apply(to: library.titles)
        let books = filter.apply(to: library.books)
        let artists = LibraryShelf.artists(filter.apply(to: library.albums))
        let games = filter.apply(to: library.games)
        let others = filter.apply(to: library.others)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                grid("Movies", titles.filter { $0.type == .movie }, minimum: 150) { title in
                    TitleCard(title: title).contextMenu { itemMenu(title.items) }
                }
                grid("Series", titles.filter { $0.type == .series }, minimum: 150) { title in
                    TitleCard(title: title).contextMenu { itemMenu(title.items) }
                }
                grid("Books", books.filter { $0.format == .ebook }, minimum: 140) { book in
                    BookCard(book: book).contextMenu { itemMenu(book.items) }
                }
                grid("Audiobooks", books.filter { $0.format == .audiobook }, minimum: 180) { book in
                    BookCard(book: book).contextMenu { itemMenu(book.items) }
                }
                grid("Music", artists, minimum: 160,
                     count: "\(artists.reduce(0) { $0 + $1.albums.count }) albums") { artist in
                    ArtistCard(artist: artist).contextMenu { itemMenu(artist.albums.flatMap(\.items)) }
                }
                grid("Games", games, minimum: 140) { game in
                    GameCard(game: game).contextMenu { itemMenu(game.items) }
                }
                if !others.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        heading("Other files", count: "\(others.count)").padding(.bottom, 8)
                        ForEach(others) { item in
                            ShelfItemRow(item: item)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                                .contextMenu { itemMenu([item]) }
                            Divider()
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func grid<Item: Identifiable, Cell: View>(
        _ title: String, _ items: [Item], minimum: CGFloat, count: String? = nil,
        @ViewBuilder cell: @escaping (Item) -> Cell
    ) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                heading(title, count: count ?? "\(items.count)")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 16)], alignment: .leading, spacing: 20) {
                    ForEach(items) { cell($0) }
                }
            }
        }
    }

    private func heading(_ title: String, count: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.bold())
            Text(count).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func itemMenu(_ items: [ShelfItem]) -> some View {
        actions.menu(items)
    }
}

// MARK: - Files

/// Every item as a table: sortable columns, several selected at once, actions in the context menu.
private struct MacLibraryFiles: View {
    let items: [ShelfItem]
    let actions: LibraryActions

    @State private var selection = Set<ShelfItem.ID>()
    @State private var order = [KeyPathComparator(\FileRow.added, order: .reverse)]

    var body: some View {
        let rows = items.map(FileRow.init).sorted(using: order)
        Table(rows, selection: $selection, sortOrder: $order) {
            TableColumn("Name", value: \.name) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).lineLimit(1)
                    if row.item.isRenamed {
                        // The service's own (random) name, so the item can still be found there.
                        Text(row.item.item.name).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .help(row.name)
            }
            .width(min: 240, ideal: 420)
            TableColumn("Service", value: \.service) { row in
                HStack(spacing: 6) {
                    BackendBadge(backend: row.item.item.backend)
                    Text(row.service)
                }
            }
            .width(min: 110, ideal: 140)
            TableColumn("Kind", value: \.kind)
                .width(min: 70, ideal: 100)
            TableColumn("Status", value: \.status)
                .width(min: 80, ideal: 120)
            // Seeding services only (Debrid-Link, TorBox on a paid plan); others show a dash.
            TableColumn("Ratio", value: \.ratio) { row in
                if let seeding = row.item.item.seeding {
                    SeedingRatio(ratio: seeding.ratio, isActive: seeding.isActive).fixedSize()
                } else {
                    Text("–").foregroundStyle(.secondary)
                }
            }
            .width(min: 60, ideal: 70)
            TableColumn("Size", value: \.size) { row in
                Text(row.size > 0 ? row.size.formatted(.byteCount(style: .file)) : "–").monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Added", value: \.added) { row in
                Text(row.added == .distantPast ? "–" : row.added.formatted(date: .abbreviated, time: .omitted))
            }
            .width(min: 80, ideal: 110)
        }
        .contextMenu(forSelectionType: ShelfItem.ID.self) { ids in
            let chosen = items.filter { ids.contains($0.id) }
            if !chosen.isEmpty {
                Button("Copy Name", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(chosen.map(\.name).joined(separator: "\n"), forType: .string)
                }
                Divider()
                actions.menu(chosen)
            }
        }
        .onDeleteCommand {
            let chosen = items.filter { selection.contains($0.id) }
            if !chosen.isEmpty { actions.delete(chosen) }
        }
    }
}

/// What a card or a row offers: download its files, delete it on its services.
@MainActor
private struct LibraryActions {
    let download: @MainActor ([ShelfItem]) -> Void
    let reveal: @MainActor ([ShelfItem]) -> Void
    let delete: @MainActor ([ShelfItem]) -> Void

    /// Items on a service are downloaded; items already on this Mac (iCloud Drive) are shown in the Finder.
    @ViewBuilder
    func menu(_ items: [ShelfItem]) -> some View {
        let local = items.filter(\.item.backend.isOnDevice)
        let ready = items.filter { item in
            guard !item.item.backend.isOnDevice else { return false }
            if case .ready = item.item.status { return true }
            return false
        }
        if !ready.isEmpty || local.isEmpty {
            Button(ready.count > 1 ? "Download \(ready.count) Items" : "Download", systemImage: "arrow.down.circle") { download(ready) }
                .disabled(ready.isEmpty)
        }
        if !local.isEmpty {
            Button("Show in Finder", systemImage: "folder") { reveal(local) }
        }
        Divider()
        Button(items.count > 1 ? "Delete \(items.count) Items…" : "Delete…", systemImage: "trash", role: .destructive) { delete(items) }
    }
}

/// A table row with plain sortable values (Table's sort comparators need non-optional, comparable fields).
private struct FileRow: Identifiable {
    let item: ShelfItem
    let name: String
    let service: String
    let kind: String
    let status: String
    /// -1 when the item does not seed, so those sort below every real ratio.
    let ratio: Double
    let size: Int64
    let added: Date

    var id: ShelfItem.ID { item.id }

    init(_ item: ShelfItem) {
        self.item = item
        name = item.name
        service = item.item.backend.displayName
        kind = item.kind.displayName
        status = item.item.status.label
        ratio = item.item.seeding?.ratio ?? -1
        size = item.item.size ?? 0
        added = item.item.addedAt ?? .distantPast
    }
}
