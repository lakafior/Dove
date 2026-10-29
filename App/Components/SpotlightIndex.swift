import CoreSpotlight
import DoveAppCore
import DoveKit
import Foundation

/// Library titles, books and the watchlist in Spotlight (CoreSpotlight, this device). A result opens the title in
/// Dove. Rebuilt after each library refresh and watchlist change, only when something changed.
@MainActor
enum SpotlightIndex {
    private static var signature: Int?
    /// Viewing a title or book donates this activity, linked to its Spotlight item: what the user opens ranks higher.
    static let viewActivity = "net.smigi.dove.view"

    /// What one Spotlight item says. Kept apart from `CSSearchableItem` so a change can be detected cheaply.
    private struct Entry: Hashable {
        var id: String
        var domain: String
        var title: String
        var description: String
        var isMovie: Bool
        var poster: URL?
        var date: Date?
        /// 0…100: library first, then books, then the watchlist (Spotlight compares Dove's items with each other).
        var rank: Int
        var isOwned: Bool
    }

    static func update(using app: AppModel) {
        var entries: [Entry] = []
        let titles = app.library.titles
        for title in titles {
            entries.append(Entry(
                id: "title:\(title.id)", domain: "library", title: title.name,
                description: [title.type == .movie ? "Movie" : "Series", title.year, title.coverage].compactMap { $0 }.joined(separator: " · "),
                isMovie: title.type == .movie, poster: title.media?.poster, date: title.latestAdded, rank: 80, isOwned: true
            ))
        }
        for book in app.library.books {
            entries.append(Entry(
                id: "book:\(book.id)", domain: "library", title: book.name,
                description: [book.format == .audiobook ? "Audiobook" : "Book", book.author].compactMap { $0 }.joined(separator: " · "),
                isMovie: false, poster: book.book?.cover, date: book.latestAdded, rank: 70, isOwned: true
            ))
        }
        for entry in app.watchlist.list.entries where Watchlist.title(for: entry, in: titles) == nil {
            entries.append(Entry(
                id: "watch:\(entry.id)", domain: "watchlist", title: entry.media.name,
                description: ["Watchlist", entry.media.type == .movie ? "Movie" : "Series", entry.media.releaseInfo].compactMap { $0 }.joined(separator: " · "),
                isMovie: entry.media.type == .movie, poster: entry.media.poster, date: entry.addedAt, rank: 60, isOwned: false
            ))
        }

        let current = entries.hashValue
        guard current != signature else { return }
        signature = current
        Task {
            var items: [CSSearchableItem] = []
            for entry in entries {
                let attributes = CSSearchableItemAttributeSet(contentType: entry.isMovie ? .movie : .content)
                attributes.title = entry.title
                attributes.displayName = entry.title
                attributes.contentDescription = entry.description
                attributes.keywords = ["Dove"]
                // Ranking signals: owned (library) or chosen (watchlist), how important within Dove, how recent.
                attributes.rankingHint = NSNumber(value: entry.rank)
                if entry.isOwned { attributes.userOwned = true } else { attributes.userCurated = true }
                attributes.lastUsedDate = entry.date
                attributes.contentCreationDate = entry.date
                // Artwork the image cache already holds; Spotlight is no reason to download posters.
                if let poster = entry.poster, ImageCache.shared.contains(poster) {
                    attributes.thumbnailData = try? await ImageCache.shared.data(for: poster)
                }
                items.append(CSSearchableItem(uniqueIdentifier: entry.id, domainIdentifier: entry.domain, attributeSet: attributes))
            }
            let index = CSSearchableIndex.default()
            try? await index.deleteAllSearchableItems()
            try? await index.indexSearchableItems(items)
        }
    }

    /// The activity a title or book screen advertises while it is open (`.userActivity`), linked to its indexed item.
    static func describe(_ activity: NSUserActivity, id: String, title: String) {
        activity.title = title
        // Demo mode's titles stay out of the system's search and suggestions.
        activity.isEligibleForSearch = !DemoMode.isActive
        #if os(iOS)
        activity.isEligibleForPrediction = !DemoMode.isActive
        #endif
        activity.userInfo = ["id": id]
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.relatedUniqueIdentifier = id
        attributes.title = title
        activity.contentAttributeSet = attributes
    }

    /// A searched title's screen (not in the library): Spotlight keeps it as history, so titles looked at but not
    /// added come back from the system search. No linked item: iOS decides how long it stays.
    static func describe(_ activity: NSUserActivity, media: MediaSummary) {
        activity.title = media.name
        // Demo mode's titles stay out of the system's search and suggestions.
        activity.isEligibleForSearch = !DemoMode.isActive
        #if os(iOS)
        activity.isEligibleForPrediction = !DemoMode.isActive
        #endif
        activity.userInfo = ["id": "media:\(media.id)", "media": (try? JSONEncoder().encode(media)) ?? Data()]
        activity.requiredUserInfoKeys = ["id", "media"]
        activity.keywords = [media.name]
        let attributes = CSSearchableItemAttributeSet(contentType: media.type == .movie ? .movie : .content)
        attributes.title = media.name
        attributes.contentDescription = [media.type == .movie ? "Movie" : "Series", media.releaseInfo].compactMap { $0 }.joined(separator: " · ")
        activity.contentAttributeSet = attributes
    }

    /// A Spotlight result for a screen's activity: an indexed item's ID, or a searched title carried whole.
    static func open(_ activity: NSUserActivity, using app: AppModel) {
        guard let id = activity.userInfo?["id"] as? String else { return }
        if id.hasPrefix("media:") {
            if let data = activity.userInfo?["media"] as? Data, let media = try? JSONDecoder().decode(MediaSummary.self, from: data) {
                app.show(.media(media))
            }
            return
        }
        open(id, using: app)
    }

    /// A tapped Spotlight result.
    static func open(_ identifier: String, using app: AppModel) {
        let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        switch parts[0] {
        case "title": app.show(.title(id: parts[1]))
        case "book": app.show(.book(id: parts[1]))
        case "watch":
            if let entry = app.watchlist.list.entries.first(where: { $0.id == parts[1] }) { app.show(.media(entry.media)) }
        default: break
        }
    }
}
