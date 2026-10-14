import Foundation

/// The last library Dove listed, so the Library tab shows it at once on launch and refreshes behind it.
/// Names, sizes, statuses and info hashes only: no links, no keys.
public struct LibraryCache: Codable, Sendable {
    /// Bump when `LibraryItem`'s encoding changes; an old file is then ignored.
    static let version = 1

    public var savedAt: Date
    public var items: [LibraryItem]
    var version = Self.version

    public init(items: [LibraryItem], savedAt: Date = .now) {
        self.items = items
        self.savedAt = savedAt
    }

    public static func load(from url: URL) -> LibraryCache? {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(LibraryCache.self, from: data),
              cache.version == version
        else { return nil }
        return cache
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// A fresh load, plus the cached items of services that did not answer this time (a timeout is not an empty
    /// library). Services no longer set up lose their items. Newest first, like `LibraryLoader`.
    public static func merge(
        fresh: [LibraryItem],
        cached: [LibraryItem],
        failed: Set<BackendID>,
        configured: Set<BackendID>
    ) -> [LibraryItem] {
        let kept = cached.filter { failed.contains($0.backend) && configured.contains($0.backend) }
        return (fresh + kept).sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
    }
}

