import AppIntents
import DoveKit
import Foundation

// Siri, Shortcuts and Spotlight actions. They run in the app's own process (the add and the audiobook without
// opening it) and go through the same code as the screens: the router's "Automatic", `DownloadJobs`, the player.

enum DoveIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    case nothingToAdd
    case noServices
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning: "Dove is still starting. Try again in a moment."
        case .nothingToAdd: "There is no magnet, link or NZB in that text."
        case .noServices: "Add a debrid service or nzbdav in Dove's Settings first."
        case .failed(let message): "\(message)"
        }
    }
}

@MainActor
private func runningModel() throws -> AppModel {
    guard let model = AppModel.current else { throw DoveIntentError.notRunning }
    return model
}

/// "Add to Dove": every magnet, link, `.torrent` or NZB link in the text, through "Automatic" (the priority list
/// with fallback), optionally as "Download only".
struct AddToDoveIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Dove"
    static let description = IntentDescription(
        "Sends the magnets and links in the text to your services, like the add sheet's Automatic. Use it after Get Clipboard or from the share sheet.",
        categoryName: "Library"
    )

    @Parameter(title: "Text", description: "A magnet, a link, or text that contains them.", inputOptions: String.IntentInputOptions(keyboardType: .URL))
    var text: String

    @Parameter(title: "Download to iPhone", description: "Download the files to this iPhone, then remove the item from the service.", default: false)
    var downloadOnly: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to Dove") { \.$downloadOnly }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let model = try runningModel()
        let sources = SourceDetector.sources(in: text)
        guard !sources.isEmpty else { throw DoveIntentError.nothingToAdd }
        guard !model.backends.isEmpty else { throw DoveIntentError.noServices }

        let router = model.router
        var added: [BackendID: Int] = [:]
        var failures: [String] = []
        for source in sources {
            do {
                let result = try await router.add(source)
                added[result.backend, default: 0] += max(result.itemIDs.count, 1)
                if downloadOnly {
                    for id in result.itemIDs {
                        _ = await model.startDownloadOnly(id, on: result.backend, name: source.displayName, pick: .allVideos)
                    }
                }
            } catch {
                failures.append(sources.count > 1 ? "\(source.displayName): \(error.localizedDescription)" : error.localizedDescription)
            }
        }
        guard !added.isEmpty else { throw DoveIntentError.failed(failures.joined(separator: "\n")) }

        var lines = [added.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.value) to \($0.key.displayName)" }
            .joined(separator: ", ")]
        lines[0] = "Added " + lines[0] + "."
        // Download-only jobs wait for the service while Dove is open (iOS has no background polling).
        if downloadOnly { lines.append("Dove downloads it to this iPhone when you open it.") }
        if !failures.isEmpty { lines.append("Not added: " + failures.joined(separator: "; ")) }
        let summary = lines.joined(separator: " ")
        return .result(value: summary, dialog: "\(summary)")
    }
}

/// Opens Dove and searches (Movies & TV, or the category on screen).
struct SearchInDoveIntent: AppIntent {
    static let title: LocalizedStringResource = "Search in Dove"
    static let description = IntentDescription("Opens Dove and searches for a movie, series or anything your indexers have.")
    static let openAppWhenRun = true

    @Parameter(title: "Search for", requestValueDialog: "What should Dove look for?")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        try runningModel().show(.search(query))
        return .result()
    }
}

/// Plays on the audiobook last listened to, from its saved place, without opening Dove.
struct ContinueAudiobookIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Continue Audiobook"
    static let description = IntentDescription("Plays the audiobook you listened to last, from where you left it.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try runningModel()
        switch await model.continueAudiobook() {
        case .playing(let name): return .result(dialog: "Playing \(name).")
        case .failed(let message): throw DoveIntentError.failed(message)
        }
    }
}

struct OpenWatchlistIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Watchlist"
    static let description = IntentDescription("Opens Dove's watchlist.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try runningModel().show(.watchlist)
        return .result()
    }
}

struct OpenDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Downloads"
    static let description = IntentDescription("Opens what is downloading to this iPhone and on your services.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try runningModel().show(.downloads)
        return .result()
    }
}

/// Ready-made shortcuts: in the Shortcuts app, in Spotlight, and by voice ("Add to Dove", "Continue my audiobook in
/// Dove"). Phrases cannot hold free text, so "Add" and "Search" ask for it.
struct DoveShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddToDoveIntent(),
            phrases: ["Add to \(.applicationName)", "Send to \(.applicationName)"],
            shortTitle: "Add to Dove",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: ContinueAudiobookIntent(),
            phrases: ["Continue my audiobook in \(.applicationName)", "Resume listening in \(.applicationName)"],
            shortTitle: "Continue Audiobook",
            systemImageName: "headphones"
        )
        AppShortcut(
            intent: SearchInDoveIntent(),
            phrases: ["Search \(.applicationName)", "Search in \(.applicationName)"],
            shortTitle: "Search",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: OpenWatchlistIntent(),
            phrases: ["Show my \(.applicationName) watchlist", "Open the watchlist in \(.applicationName)"],
            shortTitle: "Watchlist",
            systemImageName: "bookmark"
        )
        AppShortcut(
            intent: OpenDownloadsIntent(),
            phrases: ["Show \(.applicationName) downloads"],
            shortTitle: "Downloads",
            systemImageName: "arrow.down.circle"
        )
    }
}
