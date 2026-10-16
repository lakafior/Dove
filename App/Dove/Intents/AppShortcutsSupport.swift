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

// MARK: - Spotlight

/// Library titles, books and the watchlist in Spotlight (CoreSpotlight, this device). A result opens the title in
/// Dove. Rebuilt after each library refresh and watchlist change, only when something changed.
@MainActor
enum SpotlightIndex {
    private static var signature: Int?

    static func update(using app: AppModel) {
        var items: [CSSearchableItem] = []
        let titles = app.library.titles
        for title in titles {
            let attributes = CSSearchableItemAttributeSet(contentType: title.type == .movie ? .movie : .content)
            attributes.title = title.name
            attributes.contentDescription = [title.type == .movie ? "Movie" : "Series", title.year, title.coverage]
                .compactMap { $0 }.joined(separator: " · ")
            attributes.keywords = ["Dove", title.type == .movie ? "movie" : "series"]
            items.append(CSSearchableItem(uniqueIdentifier: "title:\(title.id)", domainIdentifier: "library", attributeSet: attributes))
        }
        for book in app.library.books {
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = book.name
            attributes.contentDescription = [book.format == .audiobook ? "Audiobook" : "Book", book.author].compactMap { $0 }.joined(separator: " · ")
            attributes.keywords = ["Dove", book.format == .audiobook ? "audiobook" : "book"]
            items.append(CSSearchableItem(uniqueIdentifier: "book:\(book.id)", domainIdentifier: "library", attributeSet: attributes))
        }
        for entry in app.watchlist.list.entries where Watchlist.title(for: entry, in: titles) == nil {
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = entry.media.name
            attributes.contentDescription = ["Watchlist", entry.media.type == .movie ? "Movie" : "Series", entry.media.releaseInfo]
                .compactMap { $0 }.joined(separator: " · ")
            attributes.keywords = ["Dove", "watchlist"]
            items.append(CSSearchableItem(uniqueIdentifier: "watch:\(entry.id)", domainIdentifier: "watchlist", attributeSet: attributes))
        }

        var hasher = Hasher()
        for item in items {
            hasher.combine(item.uniqueIdentifier)
            hasher.combine(item.attributeSet.title)
            hasher.combine(item.attributeSet.contentDescription)
        }
        let current = hasher.finalize()
        guard current != signature else { return }
        signature = current
        Task {
            let index = CSSearchableIndex.default()
            try? await index.deleteAllSearchableItems()
            try? await index.indexSearchableItems(items)
        }
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
