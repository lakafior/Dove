import AppIntents
import CoreSpotlight
import DoveAppCore
import DoveKit
import SwiftUI
import UIKit

// MARK: - Siri suggestions

/// Tells iOS what the user does in Dove (intent donations), so Siri can suggest it on the Lock Screen, in Spotlight
/// and in Shortcuts at the usual time: "Continue Audiobook" after listening starts, "Search in Dove" after searches.
/// Donations stay on the device.
enum SiriSuggestions {
    static func listened() {
        Task { _ = try? await IntentDonationManager.shared.donate(intent: ContinueAudiobookIntent()) }
    }

    static func searched(_ query: String) {
        // `@Parameter`'s setter is nonmutating, so a `let` intent takes the query.
        let intent = SearchInDoveIntent()
        intent.query = query
        Task { _ = try? await IntentDonationManager.shared.donate(intent: intent) }
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
