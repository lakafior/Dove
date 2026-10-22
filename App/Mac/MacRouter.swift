import DoveAppCore
import DoveKit
import Observation
import SwiftUI

/// A place in the window's sidebar.
enum SidebarItem: Hashable {
    case search
    /// The Library, all of it (nil) or one kind.
    case library(LibraryFilter.Category?)
    case downloads
    case onServices
    case watchlist
    case service(BackendID)
}

/// Where the Mac window is. `AppModel.show(_:)` (links, notifications, Spotlight) arrives here through
/// `MacPlatform`.
@MainActor
@Observable
final class MacRouter {
    var selection: SidebarItem? = .search
    /// The words in the search field (the Search page's, or the ⌘F panel's: one text for both).
    var searchText = ""
    /// The ⌘F panel over a page other than Search.
    var isQuickSearchPresented = false
    /// Bumped by ⌘F on the Search page: its field takes the focus.
    var focusSearchRequest = 0
    /// Words to search, from the sidebar's field, a link or the Services menu; the Search page runs it and clears this.
    var searchRequest: String?
    /// The Search page's stack: a title from search, a link or Spotlight.
    var searchPath = NavigationPath()
    /// Set when something asks for Settings; the window opens the Settings scene and clears it.
    var settingsRequested = false

    /// ⌘F: the Search page's field, or a floating one over any other page.
    func startSearch() {
        if selection == .search && searchPath.isEmpty {
            focusSearchRequest += 1
        } else {
            isQuickSearchPresented = true
        }
    }

    /// Something the library holds, clicked on the start page, in the Library or among suggestions. One way in, so its
    /// screen (phase 3) replaces this one method; until then the Library opens at its kind.
    enum LibraryTarget: Hashable {
        case title(LibraryTitle)
        case book(BookTitle)
        case album(AlbumTitle)
        case artist(ArtistShelf)
        case game(GameTitle)
    }

    func openLibrary(_ target: LibraryTarget) {
        isQuickSearchPresented = false
        let category: LibraryFilter.Category = switch target {
        case .title(let title): title.type == .movie ? .movies : .series
        case .book(let book): book.format == .audiobook ? .audiobooks : .books
        case .album, .artist: .music
        case .game: .games
        }
        selection = .library(category)
    }

    /// A suggestion picked under the Spotlight field (on the Search page or in the ⌘F panel).
    func open(_ suggestion: SpotlightSuggestion) {
        isQuickSearchPresented = false
        switch suggestion.target {
        case .media(let media):
            show(.media(media))
        case .held(let target):
            openLibrary(target)
        case .book(let book, let format):
            showReleases(.book(book, format))
        case .album(let album):
            showReleases(.album(album))
        case .game(let game):
            showReleases(.game(game))
        case .search(let words):
            show(.search(words))
        }
    }

    /// A book's, album's or game's releases, on the Search page.
    func showReleases(_ target: ReleaseTarget) {
        searchPath = NavigationPath()
        searchPath.append(target)
        selection = .search
    }

    /// Return in the ⌘F panel: the Search page searches the words, whatever page was open.
    func submitSearch() {
        let words = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        show(.search(words))
    }

    func show(_ destination: AppModel.Destination) {
        switch destination {
        case .search(let text):
            searchPath = NavigationPath()
            if let text { searchText = text }
            searchRequest = text
            selection = .search
        case .media(let media):
            searchPath = NavigationPath()
            searchPath.append(media)
            selection = .search
        // Library title and book screens come with phase 3; until then the search page is the closest place.
        case .title, .book:
            selection = .search
        case .watchlist:
            selection = .watchlist
        case .downloads:
            selection = .downloads
        case .library(let category):
            selection = .library(category)
        case .settings:
            settingsRequested = true
        }
    }
}
