import Foundation

/// One library item with what Dove guessed from its name.
public struct ShelfItem: Identifiable, Sendable, Hashable {
    public let item: LibraryItem
    public let guess: MediaGuess
    public var id: String { "\(item.backend.rawValue)/\(item.id)" }

    public init(item: LibraryItem) {
        self.item = item
        guess = ReleaseParser.guess(item.name)
    }
}

/// Everything the user has of one title, across debrids: "Severance" with its season packs and episodes.
public struct LibraryTitle: Identifiable, Sendable, Hashable {
    public let id: String
    public let guess: MediaGuess
    public var media: MediaSummary?
    public var items: [ShelfItem]

    public var name: String { media?.name ?? guess.title }
    public var type: MediaType { media?.type ?? guess.type }
    public var year: String? { media?.releaseInfo ?? guess.year.map(String.init) }
    public var backends: [BackendID] {
        Array(Set(items.map(\.item.backend))).sorted { $0.rawValue < $1.rawValue }
    }
    public var latestAdded: Date? { items.compactMap(\.item.addedAt).max() }
    public var size: Int64 { items.compactMap(\.item.size).reduce(0, +) }

    /// The least finished state among its items, so a title shows "downloading" until everything is ready.
    public var status: LibraryFilter.Status {
        let states = Set(items.map { LibraryFilter.Status(of: $0.item.status) })
        if states.contains(.failed) { return .failed }
        if states.contains(.active) { return .active }
        return .ready
    }

    /// Items grouped by season for series ("Season 1", "Season 2", then unknown), episode order within.
    public var seasons: [(season: Int?, items: [ShelfItem])] {
        let grouped = Dictionary(grouping: items) { $0.guess.season }
        return grouped.keys
            .sorted { ($0 ?? .max) < ($1 ?? .max) }
            .map { season in
                (season, grouped[season]!.sorted { ($0.guess.episode ?? -1, $0.item.name) < ($1.guess.episode ?? -1, $1.item.name) })
            }
    }
}

public enum LibraryShelf {
    /// Groups items by matched title (several releases of one show share its metadata ID),
    /// falling back to the guessed title when there is no match. Newest first.
    public static func titles(_ items: [ShelfItem], matches: [String: MediaSummary]) -> [LibraryTitle] {
        var titles: [String: LibraryTitle] = [:]
        var order: [String] = []
        for item in items {
            let media = matches[item.guess.key]
            let id = media.map { "media:\($0.type.rawValue):\($0.id)" } ?? "guess:\(item.guess.key)"
            if titles[id] == nil {
                titles[id] = LibraryTitle(id: id, guess: item.guess, media: media, items: [])
                order.append(id)
            }
            titles[id]!.items.append(item)
        }
        return order.compactMap { titles[$0] }
            .sorted { ($0.latestAdded ?? .distantPast) > ($1.latestAdded ?? .distantPast) }
    }
}

/// Library filters: which debrids, movies or series, status, and a text query.
public struct LibraryFilter: Equatable, Sendable {
    public enum Status: String, CaseIterable, Sendable {
        case ready, active, failed

        public init(of status: LibraryItem.Status) {
            switch status {
            case .ready: self = .ready
            case .queued, .awaitingFileSelection, .downloading: self = .active
            case .failed: self = .failed
            }
        }

        public var title: String {
            switch self {
            case .ready: "Ready"
            case .active: "Downloading"
            case .failed: "Failed"
            }
        }
    }

    /// Empty means every backend.
    public var backends: Set<BackendID> = []
    public var type: MediaType?
    public var status: Status?
    public var query = ""

    public init() {}

    public var isActive: Bool {
        !backends.isEmpty || type != nil || status != nil
    }

    public func matches(_ item: ShelfItem, title: String? = nil) -> Bool {
        if !backends.isEmpty && !backends.contains(item.item.backend) { return false }
        if let type, item.guess.type != type { return false }
        if let status, Status(of: item.item.status) != status { return false }
        return matchesQuery(item.item.name) || title.map(matchesQuery) == true
    }

    /// Keeps titles with at least one matching item, trimmed to those items.
    public func apply(to titles: [LibraryTitle]) -> [LibraryTitle] {
        titles.compactMap { title in
            if let type, title.type != type { return nil }
            var title = title
            title.items = title.items.filter { item in
                if !backends.isEmpty && !backends.contains(item.item.backend) { return false }
                if let status, Status(of: item.item.status) != status { return false }
                return matchesQuery(item.item.name) || matchesQuery(title.name)
            }
            return title.items.isEmpty ? nil : title
        }
    }

    public func apply(to items: [ShelfItem]) -> [ShelfItem] {
        items.filter { matches($0) }
    }

    private func matchesQuery(_ text: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return text.localizedCaseInsensitiveContains(query)
            || MediaGuess.normalize(text).contains(MediaGuess.normalize(query))
    }
}

public enum LibraryLoader {
    public struct Result: Sendable {
        public var items: [ShelfItem]
        public var failures: [String]
    }

    /// Every backend's items in parallel, newest first. A failing backend is reported, the rest still load.
    public static func load(_ backends: [any LibraryBackend]) async -> Result {
        await withTaskGroup(of: (BackendID, Swift.Result<[LibraryItem], any Error>).self) { group in
            for backend in backends {
                group.addTask {
                    do { return (backend.id, .success(try await backend.items())) }
                    catch { return (backend.id, .failure(error)) }
                }
            }
            var items: [ShelfItem] = []
            var failures: [String] = []
            for await (id, result) in group {
                switch result {
                case .success(let list): items += list.map(ShelfItem.init)
                case .failure(let error): failures.append("\(id.displayName): \(error.localizedDescription)")
                }
            }
            items.sort { ($0.item.addedAt ?? .distantPast) > ($1.item.addedAt ?? .distantPast) }
            return Result(items: items, failures: failures.sorted())
        }
    }
}
