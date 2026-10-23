import SwiftUI
import WidgetKit

/// Dove's desktop widgets on the Mac: the iPhone's Services, Library, Watchlist and Listening widgets, drawn from the
/// same `WidgetSnapshot` the app writes to the App Group. The Live Activity and the Control Center controls are iOS only.
@main
struct DoveMacWidgets: WidgetBundle {
    var body: some Widget {
        ServicesWidget()
        LibraryWidget()
        WatchlistWidget()
        ListeningWidget()
    }
}
