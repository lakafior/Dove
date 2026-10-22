import DoveAppCore
import DoveKit
import Observation
import SwiftUI

enum AppTab: Hashable {
    case search, library, downloads, settings
}

/// Where the iOS app is: the tab on screen and the Search tab's stack. `AppModel.show(_:)` (Siri, Spotlight, Quick
/// Actions, widgets, the home screen) arrives here through `IOSPlatform`.
@MainActor
@Observable
final class AppRouter {
    /// The tab on screen, so the home screen can send the user to Downloads or Settings.
    var selectedTab: AppTab = .search
    /// A shelf tapped on the home screen: the Library opens filtered to it, then clears this.
    var libraryCategoryRequest: LibraryFilter.Category?
    /// Words to search, from Siri, Shortcuts or a Quick Action; the Search tab runs it and clears this.
    var searchRequest: String?
    /// The Search tab's stack, so Spotlight and Quick Actions can open a title or the watchlist there.
    var searchPath = NavigationPath()

    func show(_ destination: AppModel.Destination) {
        switch destination {
        case .downloads:
            selectedTab = .downloads
            return
        case .library(let category):
            if let category { libraryCategoryRequest = category }
            selectedTab = .library
            return
        case .settings:
            selectedTab = .settings
            return
        case .search(let text):
            searchPath = NavigationPath()
            searchRequest = text
        case .title(let id):
            searchPath = NavigationPath()
            searchPath.append(TitleRoute(id: id))
        case .book(let id):
            searchPath = NavigationPath()
            searchPath.append(BookRoute(id: id))
        case .media(let media):
            searchPath = NavigationPath()
            searchPath.append(media)
        case .watchlist:
            searchPath = NavigationPath()
            searchPath.append(WatchlistRoute())
        }
        selectedTab = .search
    }
}
