import Foundation

/// What the Files working set last reported: every service and ready item with its metadata version.
/// Comparing it with a fresh `LibraryBrowser.topLevel()` gives Files its updates and deletions.
/// `generation` is the sync anchor; it moves only when something changed.
public struct LibrarySnapshot: Codable, Sendable, Equatable {
    public var generation: Int
    /// `LibraryNodeID.rawValue` → `LibraryNode.metadataVersion`.
    public var entries: [String: String]

    public init(generation: Int = 0, entries: [String: String] = [:]) {
        self.generation = generation
        self.entries = entries
    }

    public init(nodes: [LibraryNode], generation: Int = 0) {
        self.generation = generation
        self.entries = Dictionary(nodes.map { ($0.id.rawValue, $0.metadataVersion) }, uniquingKeysWith: { first, _ in first })
    }

    public struct Changes: Sendable {
        public let snapshot: LibrarySnapshot
        public let updated: [LibraryNode]
        public let deleted: [LibraryNodeID]
    }

    /// Changes from this snapshot to `nodes`. Entries of services in `failed` stay as they were:
    /// a service that did not answer has not lost its items.
    public func changes(to nodes: [LibraryNode], failed: Set<BackendID> = []) -> Changes {
        var next = entries.filter { key, _ in
            guard let backend = LibraryNodeID(rawValue: key)?.backend else { return false }
            return failed.contains(backend)
        }
        var updated: [LibraryNode] = []
        for node in nodes {
            let key = node.id.rawValue
            next[key] = node.metadataVersion
            if entries[key] != node.metadataVersion { updated.append(node) }
        }
        let deleted = entries.keys
            .filter { next[$0] == nil }
            .sorted()
            .compactMap(LibraryNodeID.init(rawValue:))
        let changed = !updated.isEmpty || !deleted.isEmpty
        return Changes(
            snapshot: LibrarySnapshot(generation: changed ? generation + 1 : generation, entries: next),
            updated: updated,
            deleted: deleted
        )
    }

    public static func load(from url: URL) -> LibrarySnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LibrarySnapshot.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
