import DoveKit
import Foundation
import Observation

/// Library state that outlives the tab: items from every backend, and their metadata matches.
@MainActor
@Observable
final class LibraryModel {
    /// Everything the services listed. Views read `items`, which leaves adult content out unless it is shown.
    private var allItems: [ShelfItem] = []
    /// Set by `AppModel` from the synced preference.
    var showAdult = false

    var items: [ShelfItem] {
        showAdult ? allItems : allItems.filter { $0.kind != .adult }
    }
    private(set) var failures: [String] = []
    private(set) var matches: [String: MediaSummary] = [:]
    /// Covers for books and audiobooks, keyed by `BookGuess.key`.
    private(set) var bookMatches: [String: BookSummary] = [:]
    private(set) var isLoading = false
    /// Something to show: the cached list from the last launch, or a finished refresh.
    private(set) var hasLoaded = false
    /// When the list on screen came from the services (the cache keeps its own date).
    private(set) var updatedAt: Date?
    /// Set once the tab has shown the cache and asked the services; later visits only refresh on request.
    private var hasStarted = false
    /// The refresh in progress: pull-to-refresh, launch and actions share it instead of racing each other.
    private var refreshTask: Task<Void, Never>?
    private(set) var isRematching = false
    /// A batch action (delete, reinsert, move) on several items: what it is and how far it got.
    private(set) var batch: (label: String, done: Int, total: Int)?

    /// Matches survive launches; they are not secrets.
    private let store = MatchStore(fileURL: URL.applicationSupportDirectory.appending(path: "Dove/library-matches.json"))
    private let bookStore = MetadataStore<BookSummary>(fileURL: URL.applicationSupportDirectory.appending(path: "Dove/library-books.json"))
    private let bookMetadata = BookMetadata()
    /// The last list, shown at once on launch while the services are asked again.
    private static let cacheURL = URL.applicationSupportDirectory.appending(path: "Dove/library-items.json")
    /// Kinds learned from an item's files once it was opened (Real-Debrid and Offcloud list items without files),
    /// and kinds the user set. In the App Group container: the Files extension hides adult items with them.
    private var kinds: KindOverrides
    private static let kindsURL = SharedConfiguration.kindsURL
    /// Where learned kinds lived before the user could set them and Files needed them.
    private static let legacyKindsURL = URL.applicationSupportDirectory.appending(path: "Dove/library-kinds.json")

    init() {
        if let current = KindOverrides.load(from: Self.kindsURL) {
            kinds = current
        } else {
            kinds = KindOverrides.load(from: Self.legacyKindsURL) ?? KindOverrides()
            if FileManager.default.fileExists(atPath: Self.legacyKindsURL.path()) {
                try? kinds.save(to: Self.kindsURL)
                try? FileManager.default.removeItem(at: Self.legacyKindsURL)
            }
        }
        if let cache = LibraryCache.load(from: Self.cacheURL) {
            allItems = cache.items.map(kinds.shelfItem)
            updatedAt = cache.savedAt
            hasLoaded = true
        }
    }

    var titles: [LibraryTitle] {
        LibraryShelf.titles(items, matches: matches)
    }

    var books: [BookTitle] {
        LibraryShelf.books(items, matches: bookMatches)
    }

    /// Music, software and the rest: listed by name under the posters.
    var others: [ShelfItem] {
        LibraryShelf.others(items)
    }

    /// Re-classifies an item from the files its detail call returned, and remembers the answer.
    func learnKind(from detail: LibraryItem) {
        guard !detail.files.isEmpty else { return }
        let learned = ShelfItem(item: detail)
        guard kinds.learned[learned.id] != learned.kind else { return }
        kinds.learned[learned.id] = learned.kind
        saveKinds()
        // The user's own choice still wins.
        guard kinds.manual[learned.id] == nil,
              let index = allItems.firstIndex(where: { $0.id == learned.id })
        else { return }
        allItems[index] = ShelfItem(item: allItems[index].item, kind: learned.kind)
    }

    /// "Change type": the user's kind for these items; nil goes back to automatic (files, then the name).
    /// Items that become video, books or audiobooks get looked up for a poster or a cover.
    func setKind(_ kind: ContentKind?, for changed: [ShelfItem], using app: AppModel) async {
        let ids = Set(changed.map(\.id))
        for id in ids { kinds.manual[id] = kind }
        saveKinds()
        allItems = allItems.map { ids.contains($0.id) ? kinds.shelfItem($0.item) : $0 }
        FilesLocation.libraryChanged()
        await matchMissing(using: app.addonSet)
        await matchMissingBooks()
    }

    /// A kind known when the item was added (an indexer's adult category), kept like the user's choice.
    func setKind(_ kind: ContentKind, backend: BackendID, itemID: LibraryItem.ID) {
        let id = ShelfItem.id(backend: backend, itemID: itemID)
        kinds.manual[id] = kind
        saveKinds()
        allItems = allItems.map { $0.id == id ? kinds.shelfItem($0.item) : $0 }
        FilesLocation.libraryChanged()
    }

    /// The kind the user set for an item, if any (for the menu's checkmark).
    func manualKind(of item: ShelfItem) -> ContentKind? {
        kinds.manual[item.id]
    }

    private func saveKinds() {
        try? kinds.save(to: Self.kindsURL)
    }

    func title(id: String) -> LibraryTitle? {
        titles.first { $0.id == id }
    }

    func book(id: String) -> BookTitle? {
        books.first { $0.id == id }
    }

    /// First visit of the tab: the cached list and its posters right away, then the services behind it.
    func start(using app: AppModel) async {
        guard !hasStarted else { return }
        hasStarted = true
        matches = await store.all().compactMapValues(\.media)
        bookMatches = await bookStore.all().compactMapValues(\.media)
        await refresh(using: app)
    }

    /// Lists every service again. A refresh already running is joined, not restarted, unless `after` an action
    /// that changed the library: then that one finishes and a new one starts.
    ///
    /// The work runs in its own task: pull-to-refresh cancels its task when the list redraws mid-refresh, which
    /// used to cancel the requests and show "cancelled" instead of the library.
    func refresh(using app: AppModel, afterChange: Bool = false) async {
        if let running = refreshTask {
            await running.value
            guard afterChange else { return }
        }
        let task = Task { await self.load(using: app) }
        refreshTask = task
        await task.value
        if refreshTask == task { refreshTask = nil }
    }

    private func load(using app: AppModel) async {
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        let result = await LibraryLoader.load(app.backends)
        // A service that did not answer keeps what it had; one without a key anymore loses it.
        let merged = LibraryCache.merge(
            fresh: result.items.map(\.item),
            cached: allItems.map(\.item),
            failed: result.failed,
            configured: Set(app.backends.map(\.id))
        )
        allItems = merged.map(kinds.shelfItem)
        failures = result.failures
        app.services.record(configured: app.backends.map(\.id), failed: result.failed, failures: result.failures)
        if result.failed.count < app.backends.count { updatedAt = .now }
        try? LibraryCache(items: merged, savedAt: updatedAt ?? .now).save(to: Self.cacheURL)
        FilesLocation.libraryChanged()
        matches = await store.all().compactMapValues(\.media)
        bookMatches = await bookStore.all().compactMapValues(\.media)
        async let titles: Void = matchMissing(using: app.addonSet)
        async let books: Void = matchMissingBooks()
        _ = await (titles, books)
    }

    /// Looks every title up again (e.g. after adding a TMDB key). The user's own choices stay, and a title
    /// keeps its old match when the new search finds nothing.
    func rematchAll(using app: AppModel) async {
        isRematching = true
        defer { isRematching = false }
        async let titles: Void = matchMissing(using: app.addonSet, everything: true)
        async let books: Void = matchMissingBooks(everything: true)
        _ = await (titles, books)
    }

    /// Looks up posters for titles without one, through TMDB or the search addon. Rows update as answers arrive.
    private func matchMissing(using addons: AddonSet, everything: Bool = false) async {
        guard addons.canSearch else { return }
        var guesses: [String: MediaGuess] = [:]
        for item in items where item.kind == .video && guesses[item.guess.key] == nil { guesses[item.guess.key] = item.guess }
        await LibraryMatcher.matchMissing(
            guesses,
            store: store,
            everything: everything,
            search: { query, type in try await addons.search(query, type: type) },
            onMatch: { key, media in await self.record(media, for: key) }
        )
    }

    private func record(_ media: MediaSummary, for key: String) {
        matches[key] = media
    }

    /// Covers for books and audiobooks from Open Library and Apple Books (no key). Two at a time: Apple allows
    /// about 20 searches a minute, and a refused search is simply tried again on the next refresh.
    private func matchMissingBooks(everything: Bool = false) async {
        var guesses: [String: BookGuess] = [:]
        for item in items {
            if let guess = item.bookGuess, guesses[guess.key] == nil { guesses[guess.key] = guess }
        }
        let metadata = bookMetadata
        await LibraryMatcher.matchMissing(
            guesses,
            store: bookStore,
            everything: everything,
            concurrency: 2,
            lookup: { try await metadata.match($0) },
            onMatch: { key, book in await self.recordBook(book, for: key) }
        )
    }

    private func recordBook(_ book: BookSummary, for key: String) {
        bookMatches[key] = book
    }

    /// The user's choice for a book; applies to every release with the same guess.
    func setBookMatch(_ book: BookSummary, for keys: Set<String>) async {
        for key in keys {
            await bookStore.set(.manual(book), for: key)
            bookMatches[key] = book
        }
    }

    /// Search for the picker ("Wrong book?").
    func searchBooks(_ query: String, format: BookFormat) async throws -> [BookSummary] {
        try await bookMetadata.search(query, format: format)
    }

    /// The user's choice for a guessed title; applies to every release with that guess.
    func setMatch(_ media: MediaSummary, for keys: Set<String>) async {
        for key in keys {
            await store.set(.manual(media), for: key)
            matches[key] = media
        }
    }

    // MARK: - Batch actions

    /// Runs `action` on every item, one at a time (Real-Debrid limits requests), then refreshes once.
    /// Failures are listed with the load failures and do not stop the rest.
    private func runBatch(
        _ label: String,
        _ items: [ShelfItem],
        using app: AppModel,
        _ action: (ShelfItem) async throws -> Void
    ) async {
        guard !items.isEmpty, batch == nil else { return }
        batch = (label, 0, items.count)
        var errors: [String] = []
        for item in items {
            do {
                try await action(item)
            } catch {
                errors.append("\(item.item.name) (\(item.item.backend.displayName)): \(error.localizedDescription)")
            }
            batch?.done += 1
        }
        batch = nil
        await refresh(using: app, afterChange: true)
        failures += errors
    }

    func delete(_ items: [ShelfItem], using app: AppModel) async {
        await runBatch("Deleting", items, using: app) { item in
            guard let backend = app.backend(item.item.backend) else { return }
            try await backend.delete(item.item.id)
        }
    }

    /// Adds each torrent or NZB again on its service and deletes the old item (`LibraryActions.reinsert`).
    func reinsert(_ items: [ShelfItem], using app: AppModel) async {
        await runBatch("Reinserting", items.filter { app.canReAdd($0.item) }, using: app) { item in
            guard let backend = app.backend(item.item.backend) else { return }
            _ = try await LibraryActions.reinsert(item.item, on: backend)
        }
    }

    /// Adds each item to `target` (torrents to debrids, NZBs to Usenet services); deletes the original after a
    /// successful add when `deleteOriginal`.
    func move(_ items: [ShelfItem], to target: BackendID, deleteOriginal: Bool, using app: AppModel) async {
        let movable = items.filter { app.moveTargets(for: $0.item).contains(target) }
        await runBatch(deleteOriginal ? "Moving" : "Copying", movable, using: app) { item in
            guard let source = app.backend(item.item.backend), let destination = app.backend(target) else { return }
            _ = try await LibraryActions.move(item.item, from: source, to: destination, deleteOriginal: deleteOriginal)
        }
    }

    /// A failure stays on screen with the other load failures, so an item never just reappears.
    func delete(_ item: ShelfItem, using app: AppModel) async {
        guard let backend = app.backend(item.item.backend) else { return }
        do {
            try await backend.delete(item.item.id)
            allItems.removeAll { $0.id == item.id }
            try? LibraryCache(items: allItems.map(\.item), savedAt: updatedAt ?? .now).save(to: Self.cacheURL)
            FilesLocation.libraryChanged()
        } catch {
            failures.append("Could not delete \(item.item.name) from \(item.item.backend.displayName): \(error.localizedDescription)")
        }
    }
}
