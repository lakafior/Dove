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
    /// Kinds learned from an item's files once it was opened (Real-Debrid and Offcloud list items without files).
    private var knownKinds: [ShelfItem.ID: ContentKind] = [:]
    private static let kindsURL = URL.applicationSupportDirectory.appending(path: "Dove/library-kinds.json")

    init() {
        if let data = try? Data(contentsOf: Self.kindsURL),
           let kinds = try? JSONDecoder().decode([ShelfItem.ID: ContentKind].self, from: data) {
            knownKinds = kinds
        }
    }

    var titles: [LibraryTitle] {
        LibraryShelf.titles(items, matches: matches)
    }

    /// Music, books, software and the rest: listed by name under the posters.
    var others: [ShelfItem] {
        LibraryShelf.others(items)
    }

    /// Re-classifies an item from the files its detail call returned, and remembers the answer.
    func learnKind(from detail: LibraryItem) {
        guard !detail.files.isEmpty else { return }
        let learned = ShelfItem(item: detail)
        guard let index = items.firstIndex(where: { $0.id == learned.id }) else { return }
        guard items[index].kind != learned.kind || knownKinds[learned.id] == nil else { return }
        knownKinds[learned.id] = learned.kind
        items[index] = ShelfItem(item: items[index].item, kind: learned.kind)
        try? FileManager.default.createDirectory(at: Self.kindsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(knownKinds).write(to: Self.kindsURL, options: .atomic)
    }

    func title(id: String) -> LibraryTitle? {
        titles.first { $0.id == id }
    }

    func refresh(using app: AppModel) async {
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        let result = await LibraryLoader.load(app.backends)
        items = result.items.map { item in
            knownKinds[item.id].map { ShelfItem(item: item.item, kind: $0) } ?? item
        }
        failures = result.failures
        FilesLocation.libraryChanged()
        matches = await store.all().compactMapValues(\.media)
        await matchMissing(using: app.addonSet)
    }

    /// Looks up posters for titles without one, through the search addon. Rows update as answers arrive.
    private func matchMissing(using addons: AddonSet) async {
        guard addons.canSearch else { return }
        var guesses: [String: MediaGuess] = [:]
        for item in items where item.kind == .video && guesses[item.guess.key] == nil { guesses[item.guess.key] = item.guess }
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

    /// A failure stays on screen with the other load failures, so an item never just reappears.
    func delete(_ item: ShelfItem, using app: AppModel) async {
        guard let backend = app.backend(item.item.backend) else { return }
        do {
            try await backend.delete(item.item.id)
            items.removeAll { $0.id == item.id }
            FilesLocation.libraryChanged()
        } catch {
            failures.append("Could not delete \(item.item.name) from \(item.item.backend.displayName): \(error.localizedDescription)")
        }
    }
}
