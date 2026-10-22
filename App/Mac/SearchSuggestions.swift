import DoveAppCore
import DoveKit
import Observation
import SwiftUI

/// One line under the Spotlight field.
struct SpotlightSuggestion: Identifiable, Hashable {
    enum Target: Hashable {
        /// Something the library holds: opens the way the Library opens it.
        case held(MacRouter.LibraryTarget)
        /// A movie or series from TMDB or the metadata addons: opens with its sources.
        case media(MediaSummary)
        /// A book, album or game from the metadata services: its releases (the next step on the Mac; until then a
        /// search for its name).
        case book(BookSummary)
        case album(AlbumSummary)
        case game(GameSummary)
        /// Search for the words (the last line).
        case search(String)
    }

    let id: String
    let target: Target
    let title: String
    let subtitle: String?
    let image: URL?
    /// Width ÷ height of the image (posters 2:3, albums square, game boxes 3:4).
    var ratio: CGFloat = 2 / 3
    let symbol: String
}

/// Suggestions while the words are typed, Spotlight style, in every category with metadata: what the library holds
/// first (local, free), then a few from the category's services after a pause in typing (TMDB or addons, Open
/// Library/Apple Books/plugins, MusicBrainz/Apple Music, IGDB/Wikidata), then "Search for …". Software, Adult and All
/// have no metadata: only the search line.
@MainActor
@Observable
final class SearchSuggestions {
    private(set) var items: [SpotlightSuggestion] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    func update(_ text: String, category: SearchCategory, model: AppModel) {
        task?.cancel()
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard words.count >= 2 else {
            items = []
            return
        }
        let held = Self.held(words, category: category, in: model.library)
        let search = Self.searchLine(words, category: category)
        items = held + [search]
        task = Task {
            // A pause in typing, so each keystroke does not cost a search (MusicBrainz allows one call a second).
            try? await Task.sleep(for: .milliseconds(category == .music ? 500 : 300))
            guard !Task.isCancelled, let found = await Self.remote(words, category: category, model: model), !Task.isCancelled else { return }
            let heldNames = Set(held.map { $0.title.lowercased() })
            let remote = found.filter { !heldNames.contains($0.title.lowercased()) }.prefix(6)
            items = held + remote + [search]
        }
    }

    func clear() {
        task?.cancel()
        items = []
    }

    // MARK: - From the services

    private static func remote(_ words: String, category: SearchCategory, model: AppModel) async -> [SpotlightSuggestion]? {
        switch category {
        case .media:
            guard model.addonSet.canSearch, let found = try? await model.addonSet.search(words) else { return nil }
            return found.map { media in
                SpotlightSuggestion(
                    id: "media:\(media.id)", target: .media(media), title: media.name,
                    subtitle: [media.releaseInfo, media.type == .movie ? "Movie" : "Series"].compactMap { $0 }.joined(separator: " · "),
                    image: media.poster, symbol: media.type == .movie ? "film" : "tv"
                )
            }
        case .books, .audiobooks:
            let format: BookFormat = category == .audiobooks ? .audiobook : .ebook
            guard let found = try? await model.library.searchBooks(words, format: format) else { return nil }
            return BookSummary.unique(found).map { book in
                SpotlightSuggestion(
                    id: "book:\(book.id)", target: .book(book), title: book.title,
                    subtitle: [book.authors.first, book.year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                    image: book.cover, ratio: format.coverRatio, symbol: category.symbolName
                )
            }
        case .music:
            guard let found = try? await model.musicMetadata.search(words) else { return nil }
            return found.map { album in
                SpotlightSuggestion(
                    id: "album:\(album.id)", target: .album(album), title: album.title,
                    subtitle: [album.artists.first, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                    image: album.cover, ratio: 1, symbol: "music.note"
                )
            }
        case .games:
            guard let found = try? await model.gameMetadata.search(words) else { return nil }
            return found.map { game in
                SpotlightSuggestion(
                    id: "game:\(game.id)", target: .game(game), title: game.title,
                    subtitle: ([game.year.map(String.init)] + game.platforms.prefix(2).map(\.displayName)).compactMap { $0 }.joined(separator: " · "),
                    image: game.cover, ratio: 3 / 4, symbol: "gamecontroller"
                )
            }
        default:
            return nil
        }
    }

    // MARK: - From the library

    /// What the library holds in this category whose name holds every typed word.
    private static func held(_ words: String, category: SearchCategory, in library: LibraryModel) -> [SpotlightSuggestion] {
        let parts = words.lowercased().split(separator: " ")
        func matches(_ text: String) -> Bool { parts.allSatisfy { text.lowercased().contains($0) } }
        let subtitle = "In your library"
        switch category {
        case .media:
            return library.titles.filter { matches($0.name) }.prefix(3).map { title in
                SpotlightSuggestion(id: "held:\(title.id)", target: .held(.title(title)), title: title.name,
                                    subtitle: [subtitle, title.year].compactMap { $0 }.joined(separator: " · "),
                                    image: title.media?.poster, symbol: "books.vertical")
            }
        case .books, .audiobooks:
            let format: BookFormat = category == .audiobooks ? .audiobook : .ebook
            return library.books.filter { $0.format == format && matches("\($0.name) \($0.author ?? "")") }.prefix(3).map { book in
                SpotlightSuggestion(id: "held:\(book.id)", target: .held(.book(book)), title: book.name,
                                    subtitle: [subtitle, book.author].compactMap { $0 }.joined(separator: " · "),
                                    image: book.book?.cover, ratio: format.coverRatio, symbol: "books.vertical")
            }
        case .music:
            return library.albums.filter { matches("\($0.name) \($0.artist ?? "")") }.prefix(3).map { album in
                SpotlightSuggestion(id: "held:\(album.id)", target: .held(.album(album)), title: album.name,
                                    subtitle: [subtitle, album.artist].compactMap { $0 }.joined(separator: " · "),
                                    image: album.album?.cover, ratio: 1, symbol: "books.vertical")
            }
        case .games:
            return library.games.filter { matches($0.name) }.prefix(3).map { game in
                SpotlightSuggestion(id: "held:\(game.id)", target: .held(.game(game)), title: game.name,
                                    subtitle: [subtitle, game.year].compactMap { $0 }.joined(separator: " · "),
                                    image: game.cover, ratio: 3 / 4, symbol: "books.vertical")
            }
        default:
            return []
        }
    }

    private static func searchLine(_ words: String, category: SearchCategory) -> SpotlightSuggestion {
        SpotlightSuggestion(id: "search:\(words)", target: .search(words), title: "Search for \u{201C}\(words)\u{201D}",
                            subtitle: category.displayName, image: nil, symbol: "magnifyingglass")
    }
}
