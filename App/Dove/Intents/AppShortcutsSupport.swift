import AppIntents
import CoreSpotlight
import DoveKit
import SwiftUI
import UIKit

// MARK: - Continue listening

extension AppModel {
    enum ContinueResult {
        case playing(String)
        case failed(String)
    }

    /// The audiobook listened to last that is still in the library, from its saved place (Siri, Shortcuts, the
    /// app icon's Quick Action). Plays on if it is already loaded.
    func continueAudiobook() async -> ContinueResult {
        if let session = audiobook.session {
            if !audiobook.isPlaying { audiobook.play() }
            return .playing(session.title)
        }
        let books = library.books
        guard let book = audiobook.listening().lazy.compactMap({ entry in books.first { $0.guess.key == entry.key } }).first else {
            return .failed("No audiobook to continue. Start one in Dove first.")
        }
        if let refusal = await playAudiobook(book) { return .failed(refusal) }
        return .playing(book.name)
    }
}

// MARK: - Siri suggestions

/// Tells iOS what the user does in Dove (intent donations), so Siri can suggest it on the Lock Screen, in Spotlight
/// and in Shortcuts at the usual time: "Continue Audiobook" after listening starts, "Search in Dove" after searches.
/// Donations stay on the device.
enum SiriSuggestions {
    static func listened() {
        Task { _ = try? await IntentDonationManager.shared.donate(intent: ContinueAudiobookIntent()) }
    }

    static func searched(_ query: String) {
        var intent = SearchInDoveIntent()
        intent.query = query
        Task { _ = try? await IntentDonationManager.shared.donate(intent: intent) }
    }
}

// MARK: - Spotlight

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
                if let poster = entry.poster, await ImageCache.shared.contains(poster) {
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
        activity.isEligibleForSearch = true
        activity.isEligibleForPrediction = true
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
        activity.isEligibleForSearch = true
        activity.isEligibleForPrediction = true
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

// MARK: - Quick Actions

/// The app icon's menu: static actions from Info.plist (`UIApplicationShortcutItems`, project.yml) and "Continue
/// <audiobook>" set while Dove goes to the background.
@MainActor
enum QuickActions {
    static let addFromClipboard = "net.smigi.dove.add-clipboard"
    static let search = "net.smigi.dove.search"
    static let watchlist = "net.smigi.dove.watchlist"
    static let downloads = "net.smigi.dove.downloads"
    static let continueAudiobook = "net.smigi.dove.continue-audiobook"

    @discardableResult
    static func perform(_ type: String) -> Bool {
        guard let app = AppModel.current else { return false }
        switch type {
        case addFromClipboard:
            // The user asked for the clipboard, so iOS's paste prompt is expected here (never on appear).
            let text = [UIPasteboard.general.string, UIPasteboard.general.url?.absoluteString].compactMap { $0 }.joined(separator: "\n")
            let sources = SourceDetector.sources(in: text)
            if sources.isEmpty { app.show(.search(nil)) } else { app.openedSource = SourceBatch(sources) }
        case search: app.show(.search(nil))
        case watchlist: app.show(.watchlist)
        case downloads: app.show(.downloads)
        case continueAudiobook: Task { _ = await app.continueAudiobook() }
        default: return false
        }
        return true
    }

    /// "Continue <book>" on top of the static actions, while there is a book to continue.
    static func updateDynamic(using app: AppModel) {
        let books = app.library.books
        let book = app.audiobook.listening().lazy.compactMap { entry in books.first { $0.guess.key == entry.key } }.first
        UIApplication.shared.shortcutItems = book.map {
            [UIApplicationShortcutItem(
                type: continueAudiobook,
                localizedTitle: "Continue Listening",
                localizedSubtitle: $0.name,
                icon: UIApplicationShortcutIcon(systemImageName: "headphones")
            )]
        } ?? []
    }
}

/// Receives Quick Actions while Dove runs; a cold launch hands its action to `AppDelegate`.
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem) async -> Bool {
        await MainActor.run { QuickActions.perform(shortcutItem.type) }
    }
}
