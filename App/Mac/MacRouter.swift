import DoveAppCore
import DoveKit
import Observation

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
    /// Words to search, from a link or the Services menu; the Search page runs it and clears this.
    var searchRequest: String?
    /// Set when something asks for Settings; the window opens the Settings scene and clears it.
    var settingsRequested = false

    func show(_ destination: AppModel.Destination) {
        switch destination {
        case .search(let text):
            searchRequest = text
            selection = .search
        // Title, book and media screens come with phase 3; until then the search page is the closest place.
        case .title, .book, .media:
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
