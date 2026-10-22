import DoveAppCore
import DoveKit
import SwiftUI

/// What one shelf on the home screen holds: its kind, how many titles or items, a few covers.
struct LibraryShelfSummary: Identifiable {
    let category: LibraryFilter.Category
    let count: Int
    let covers: [URL]
    var id: LibraryFilter.Category { category }

    /// Square covers for audiobooks and albums, 3:4 boxes for games, 2:3 for the rest.
    var coverRatio: CGFloat { category == .audiobooks || category == .music ? 1 : category == .games ? 3 / 4 : 2 / 3 }

    var symbol: String {
        switch category {
        case .movies: "film"
        case .series: "tv"
        case .music: "music.note"
        case .books: "book.closed"
        case .audiobooks: "headphones"
        case .games: "gamecontroller"
        case .software: "app.badge"
        case .adult: "eye.slash"
        case .other: "shippingbox"
        }
    }

    /// Kinds in the Library's own order, empty ones left out. Movies and series count titles (releases of one
    /// title are one), books count books, music counts albums, games count games, the rest count items.
    @MainActor
    static func all(in library: LibraryModel, showAdult: Bool) -> [LibraryShelfSummary] {
        let titles = library.titles
        let books = library.books
        let items = library.items
        return LibraryFilter.Category.allCases.compactMap { category in
            if category == .adult && !showAdult { return nil }
            let count: Int
            let covers: [URL]
            switch category {
            case .movies, .series:
                let matching = titles.filter { ($0.type == .movie) == (category == .movies) }
                    .sorted { ($0.latestAdded ?? .distantPast) > ($1.latestAdded ?? .distantPast) }
                count = matching.count
                covers = matching.compactMap(\.media?.poster)
            case .books, .audiobooks:
                let matching = books.filter { ($0.format == .audiobook) == (category == .audiobooks) }
                count = matching.count
                covers = matching.compactMap(\.book?.cover)
            case .music:
                let albums = library.albums
                count = albums.count
                covers = albums.compactMap(\.album?.cover)
            case .games:
                let games = library.games
                count = games.count
                covers = games.compactMap(\.cover)
            case .software, .adult, .other:
                count = items.filter(category.contains).count
                covers = []
            }
            guard count > 0 else { return nil }
            // Unique: several releases may share a poster.
            let unique = covers.reduce(into: [URL]()) { if !$0.contains($1) { $0.append($1) } }
            return LibraryShelfSummary(category: category, count: count, covers: Array(unique.prefix(3)))
        }
    }
}
