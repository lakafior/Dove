import DoveAppCore
import DoveKit
import SwiftUI

/// The Library's navigation stack for one sidebar entry: its page at the root, and the item screens pushed over it. The
/// path is `MacRouter.libraryPath`, so the window's Back button and a sidebar click both work from there. Series,
/// season, artist and album have their own screens; everything else is the release page (`MacItemView`).
struct MacLibraryStack: View {
    @Environment(MacRouter.self) private var router
    let category: LibraryFilter.Category?
    var service: BackendID?

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.libraryPath) {
            MacLibraryView(category: category, service: service)
                .navigationDestination(for: MacRouter.LibraryTarget.self) { target in
                    detail(of: target)
                }
                .navigationDestination(for: SeasonRoute.self) { route in
                    MacSeasonView(title: route.title, number: route.number)
                }
                // "Find" on a missing episode opens the title's sources (the search results' page).
                .navigationDestination(for: MediaSummary.self) { MacTitleView(media: $0) }
                .navigationDestination(for: UpgradeRoute.self) { MacUpgradeView(route: $0) }
                .navigationDestination(for: ReleaseTarget.self) { MacReleasesView(target: $0) }
        }
    }

    @ViewBuilder
    private func detail(of target: MacRouter.LibraryTarget) -> some View {
        switch target {
        case .title(let title) where title.type == .series:
            MacSeriesView(title: title)
        case .artist(let artist):
            MacArtistView(artist: artist)
        case .album(let album):
            MacAlbumView(album: album)
        default:
            MacItemView(target: target)
        }
    }
}
