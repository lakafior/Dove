import AppKit
import DoveAppCore
import DoveKit
import SwiftUI

/// The Library as icons: cover grids, one per kind, in the iPhone's order: movies, series, books, audiobooks, music,
/// games, then the files that belong to no title. A click opens the title's screen over the Library.
struct MacLibraryTitles: View {
    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router
    let filter: LibraryFilter
    let actions: MacLibraryActions
    /// The Library page's selection, shared with the list and the toolbar's Share and Action menu.
    @Binding var selection: Set<String>
    /// Where a ⇧-click range starts: the last plain or ⌘-click.
    @State private var anchor: String?

    private var library: LibraryModel { model.library }

    var body: some View {
        let titles = filter.apply(to: library.titles)
        let books = filter.apply(to: library.books)
        let artists = LibraryShelf.artists(filter.apply(to: library.albums))
        let games = filter.apply(to: library.games)
        let others = filter.apply(to: library.others)
        let movies = titles.filter { $0.type == .movie }, series = titles.filter { $0.type == .series }
        let ebooks = books.filter { $0.format == .ebook }, audiobooks = books.filter { $0.format == .audiobook }
        // The icons' reading order, for ⇧-click ranges and Return.
        let order: [MacRouter.LibraryTarget] = movies.map { .title($0) } + series.map { .title($0) }
            + ebooks.map { .book($0) } + audiobooks.map { .book($0) } + artists.map { .artist($0) }
            + games.map { .game($0) } + others.map { .item($0) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                grid("Movies", movies, minimum: 150) { title in
                    tile(.title(title), in: order) { TitleCard(title: title) }
                }
                grid("Series", series, minimum: 150) { title in
                    tile(.title(title), in: order) { TitleCard(title: title) }
                }
                grid("Books", ebooks, minimum: 140) { book in
                    tile(.book(book), in: order) { BookCard(book: book) }
                }
                grid("Audiobooks", audiobooks, minimum: 180) { book in
                    tile(.book(book), in: order) { BookCard(book: book) }
                }
                grid("Music", artists, minimum: 160,
                     count: "\(artists.reduce(0) { $0 + $1.albums.count }) albums") { artist in
                    tile(.artist(artist), in: order) { ArtistCard(artist: artist) }
                }
                grid("Games", games, minimum: 140) { game in
                    tile(.game(game), in: order) { GameCard(game: game) }
                }
                if !others.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        heading("Other files", count: "\(others.count)").padding(.bottom, 8)
                        ForEach(others) { item in
                            tile(.item(item), in: order) {
                                ShelfItemRow(item: item).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Divider()
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A click between the icons clears the selection, as in the Finder.
            .background { Color.clear.contentShape(.rect).onTapGesture { selection = [] } }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard let first = order.first(where: { selection.contains($0.rowID) }) else { return .ignored }
            router.openLibrary(first)
            return .handled
        }
        .onKeyPress(.escape) {
            guard !selection.isEmpty else { return .ignored }
            selection = []
            return .handled
        }
        .onDeleteCommand {
            let chosen = order.filter { selection.contains($0.rowID) }.flatMap(\.items)
            if !chosen.isEmpty { actions.delete(chosen) }
        }
    }

    /// A card as the Finder treats an icon: a click selects it (⌘ adds or removes, ⇧ extends from the last click),
    /// a double-click opens it, a right-click acts on the selection when the card is part of it, else on the card.
    private func tile<Card: View>(
        _ target: MacRouter.LibraryTarget, in order: [MacRouter.LibraryTarget], @ViewBuilder card: () -> Card
    ) -> some View {
        let id = target.rowID
        let isSelected = selection.contains(id)
        return card()
            .padding(5)
            .background {
                if isSelected { RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.25)) }
            }
            .overlay {
                if isSelected { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2) }
            }
            .contentShape(.rect)
            .onTapGesture(count: 2) { router.openLibrary(target) }
            .simultaneousGesture(TapGesture().onEnded { click(id, in: order.map(\.rowID)) })
            .contextMenu {
                let targets = isSelected ? order.filter { selection.contains($0.rowID) } : [target]
                actions.targetMenu(targets) { router.openLibrary($0) }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func click(_ id: String, in order: [String]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if flags.contains(.shift), let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            selection.formUnion(order[min(from, to)...max(from, to)])
        } else {
            selection = [id]
            anchor = id
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
}
