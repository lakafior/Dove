import AppKit
import DoveAppCore
import DoveKit
import SwiftUI

/// The Library as one table of titles, the same rows the icons show: movies, series, books, audiobooks, artists, games,
/// and the files that belong to no title (opened as items). Double-click or Return opens the title over the Library;
/// the context menu holds the actions for the selected rows.
struct MacLibraryTitleTable: View {
    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router
    let filter: LibraryFilter
    let actions: MacLibraryActions

    /// The Library page's selection, shared with the icons and the toolbar's Share and Action menu.
    @Binding var selection: Set<TitleRow.ID>
    @State private var order = [KeyPathComparator(\TitleRow.added, order: .reverse)]

    var body: some View {
        let rows = TitleRow.rows(filter: filter, library: model.library).sorted(using: order)
        Table(rows, selection: $selection, sortOrder: $order) {
            TableColumn("Name", value: \.name) { row in
                Text(row.name).lineLimit(1).help(row.name)
            }
            .width(min: 220, ideal: 380)
            TableColumn("Kind", value: \.kind)
                .width(min: 70, ideal: 90)
            TableColumn("Year", value: \.year)
                .width(min: 50, ideal: 60)
            TableColumn("Services", value: \.services) { row in
                HStack(spacing: 4) {
                    ForEach(row.backends, id: \.self) { BackendBadge(backend: $0) }
                }
            }
            .width(min: 90, ideal: 110)
            TableColumn("Size", value: \.size) { row in
                Text(row.size > 0 ? row.size.formatted(.byteCount(style: .file)) : "–").monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Added", value: \.added) { row in
                Text(row.added == .distantPast ? "–" : row.added.formatted(date: .abbreviated, time: .omitted))
            }
            .width(min: 80, ideal: 100)
            TableColumn("Status", value: \.status) { row in
                Text(row.status).foregroundStyle(row.statusColor)
            }
            .width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: TitleRow.ID.self) { ids in
            let chosen = rows.filter { ids.contains($0.id) }
            actions.targetMenu(chosen.map(\.target)) { router.openLibrary($0) }
        } primaryAction: { ids in
            // Double-click or Return: the first selected row, in the table's order.
            if let first = rows.first(where: { ids.contains($0.id) }) { router.openLibrary(first.target) }
        }
        .onDeleteCommand {
            let chosen = rows.filter { selection.contains($0.id) }.flatMap(\.items)
            if !chosen.isEmpty { actions.delete(chosen) }
        }
    }
}

/// One title, book, artist, game or loose file as a table row, with plain sortable values (Table's sort comparators
/// need non-optional, comparable fields).
struct TitleRow: Identifiable {
    let id: String
    /// Where a double-click or Return goes (`MacRouter.openLibrary`).
    let target: MacRouter.LibraryTarget
    let name: String
    let kind: String
    let year: String
    let backends: [BackendID]
    let size: Int64
    let added: Date
    let status: String
    let statusColor: Color
    /// Every release behind the row (a title's, an artist's albums').
    let items: [ShelfItem]

    /// The Library's rows in the icons' order: movies, series, books, audiobooks, artists, games, loose files.
    @MainActor
    static func rows(filter: LibraryFilter, library: LibraryModel) -> [TitleRow] {
        var rows: [TitleRow] = []
        for title in filter.apply(to: library.titles) {
            rows.append(TitleRow(
                id: "title:\(title.id)", target: .title(title), name: title.name,
                kind: title.type == .movie ? "Movie" : "Series", year: title.year ?? "", items: title.items,
                status: title.status, added: title.latestAdded, size: title.size
            ))
        }
        for book in filter.apply(to: library.books) {
            rows.append(TitleRow(
                id: "book:\(book.id)", target: .book(book), name: book.name,
                kind: book.format == .audiobook ? "Audiobook" : "Book", year: book.year ?? "", items: book.items,
                status: book.status, added: book.latestAdded, size: book.size
            ))
        }
        for artist in LibraryShelf.artists(filter.apply(to: library.albums)) {
            let items = artist.albums.flatMap(\.items)
            // The least finished state among its releases, as `LibraryFilter.Status(least:)` gives a title.
            let states = Set(items.map { LibraryFilter.Status(of: $0.item.status) })
            let status: LibraryFilter.Status = states.contains(.failed) ? .failed : states.contains(.active) ? .active : .ready
            rows.append(TitleRow(
                id: "artist:\(artist.id)", target: .artist(artist), name: artist.name,
                kind: "Artist", year: "", items: items,
                status: status, added: artist.latestAdded, size: items.compactMap(\.item.size).reduce(0, +)
            ))
        }
        for game in filter.apply(to: library.games) {
            rows.append(TitleRow(
                id: "game:\(game.id)", target: .game(game), name: game.name,
                kind: "Game", year: game.year ?? "", items: game.items,
                status: game.status, added: game.latestAdded, size: game.size
            ))
        }
        for item in filter.apply(to: library.others) {
            rows.append(TitleRow(
                id: "item:\(item.id)", target: .item(item), name: item.name,
                kind: item.kind.displayName, year: "", items: [item],
                status: LibraryFilter.Status(of: item.item.status), added: item.item.addedAt, size: item.item.size ?? 0
            ))
        }
        return rows
    }

    /// Set from the parts a row needs; the table's own fields are derived here.
    private init(
        id: String, target: MacRouter.LibraryTarget, name: String, kind: String, year: String, items: [ShelfItem],
        status: LibraryFilter.Status, added: Date?, size: Int64
    ) {
        self.id = id
        self.target = target
        self.name = name
        self.kind = kind
        self.year = year
        self.items = items
        backends = Array(Set(items.map(\.item.backend))).sorted { $0.rawValue < $1.rawValue }
        self.size = size
        self.added = added ?? .distantPast
        self.status = Self.label(status)
        statusColor = status == .failed ? .red : status == .active ? .blue : .secondary
    }

    private static func label(_ status: LibraryFilter.Status) -> String {
        switch status {
        case .ready: "Ready"
        case .active: "Downloading"
        case .failed: "Failed"
        }
    }
}

extension TitleRow {
    /// Sorted by what the Services column shows, so badges sort by name.
    var services: String { backends.map(\.displayName).joined(separator: ", ") }
}
