import DoveKit
import SwiftUI

struct WatchlistRoute: Hashable {}

extension AppModel {
    /// Adds or removes a title, then fetches what the watchlist needs for it (a series' episodes, a movie's dates).
    func toggleWatchlist(_ media: MediaSummary, otherIDs: [String] = []) {
        watchlist.toggle(media, otherIDs: otherIDs)
        SpotlightIndex.update(using: self)
        guard watchlist.contains(media) else { return }
        Task {
            await review.run(using: self)
            await watchlist.refresh(using: self)
        }
    }
}

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

/// Everything on the watchlist with what it is up to; a tap opens the library title when held, else the title screen
/// with its sources.
struct WatchlistView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let titles = model.library.titles
        List {
            ForEach(model.watchlist.list.entries) { entry in
                let held = Watchlist.title(for: entry, in: titles)
                Group {
                    if let held {
                        NavigationLink(value: TitleRoute(id: held.id)) { WatchlistRow(entry: entry) }
                    } else {
                        NavigationLink(value: entry.media) { WatchlistRow(entry: entry) }
                    }
                }
                .swipeActions {
                    Button("Remove", systemImage: "bookmark.slash", role: .destructive) { model.watchlist.remove(entry) }
                }
            }
        }
        .overlay {
            if model.watchlist.list.entries.isEmpty {
                ContentUnavailableView(
                    "Nothing saved yet",
                    systemImage: "bookmark",
                    description: Text("Tap the bookmark on a movie or series, or touch and hold a search result.")
                )
            }
        }
        .navigationTitle("Watchlist")
        .toolbar {
            let held = model.watchlist.moviesInLibrary(titles)
            if held > 0 {
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Remove \(held) movie\(held == 1 ? "" : "s") in your library", systemImage: "checkmark.circle") {
                        model.watchlist.removeMoviesInLibrary(titles)
                    }
                }
            }
        }
    }
}

private struct WatchlistRow: View {
    @Environment(AppModel.self) private var model
    let entry: Watchlist.Entry

    var body: some View {
        HStack(spacing: 12) {
            CachedImage(url: entry.media.poster) { Rectangle().fill(.quaternary) }
                .frame(width: 46, height: 69)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.media.name).font(.headline).lineLimit(2)
                Text([entry.media.type == .movie ? "Movie" : "Series", entry.media.releaseInfo].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let status = model.watchlist.status(of: entry, using: model) {
                    Text(status.label())
                        .font(.caption.weight(.medium))
                        .foregroundStyle(status.announcement != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
            }
        }
    }
}
