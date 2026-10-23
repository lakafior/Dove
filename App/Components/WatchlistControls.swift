import DoveAppCore
import DoveKit
import SwiftUI

/// The bookmark in a title screen's toolbar.
struct WatchlistButton: View {
    @Environment(AppModel.self) private var model
    let media: MediaSummary
    var otherIDs: [String] = []

    var body: some View {
        let saved = model.watchlist.contains(media) || otherIDs.contains { model.watchlist.contains(MediaSummary(id: $0, type: media.type, name: media.name)) }
        Button(saved ? "Remove from Watchlist" : "Add to Watchlist", systemImage: saved ? "bookmark.fill" : "bookmark") {
            model.toggleWatchlist(media, otherIDs: otherIDs)
        }
    }
}

/// The same as a context-menu item (search results, posters).
struct WatchlistMenuItem: View {
    @Environment(AppModel.self) private var model
    let media: MediaSummary

    var body: some View {
        if model.watchlist.contains(media) {
            Button("Remove from Watchlist", systemImage: "bookmark.slash") { model.toggleWatchlist(media) }
        } else {
            Button("Add to Watchlist", systemImage: "bookmark") { model.toggleWatchlist(media) }
        }
    }
}
