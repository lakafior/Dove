import DoveKit
import Foundation
import Observation

/// Library state that outlives the tab: items from every backend, and their metadata matches.
@MainActor
@Observable
final class LibraryModel {
    private(set) var items: [ShelfItem] = []
    private(set) var failures: [String] = []
    private(set) var matches: [String: MediaSummary] = [:]
    private(set) var isLoading = false
    private(set) var hasLoaded = false

    /// Matches survive launches; they are not secrets.
    private let store = MatchStore(fileURL: URL.applicationSupportDirectory.appending(path: "Dove/library-matches.json"))

    var titles: [LibraryTitle] {
        LibraryShelf.titles(items, matches: matches)
    }

    func title(id: String) -> LibraryTitle? {
        titles.first { $0.id == id }
    }

    func refresh(using app: AppModel) async {
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        let result = await LibraryLoader.load(app.backends)
        items = result.items
        failures = result.failures
        matches = await store.all().compactMapValues(\.media)
        await matchMissing(using: app.addonSet)
    }

    /// Looks up posters for titles without one, through the search addon. Rows update as answers arrive.
    private func matchMissing(using addons: AddonSet) async {
        guard addons.canSearch else { return }
        var guesses: [String: MediaGuess] = [:]
        for item in items where guesses[item.guess.key] == nil { guesses[item.guess.key] = item.guess }
        await LibraryMatcher.matchMissing(
            guesses,
            store: store,
            search: { query, type in try await addons.search(query, type: type) },
            onMatch: { key, media in await self.record(media, for: key) }
        )
    }

    private func record(_ media: MediaSummary, for key: String) {
        matches[key] = media
    }

    /// The user's choice for a guessed title; applies to every release with that guess.
    func setMatch(_ media: MediaSummary, for keys: Set<String>) async {
        for key in keys {
            await store.set(.manual(media), for: key)
            matches[key] = media
        }
    }

    func delete(_ item: ShelfItem, using app: AppModel) async throws {
        guard let backend = app.backend(item.item.backend) else { return }
        try await backend.delete(item.item.id)
        items.removeAll { $0.id == item.id }
    }
}
