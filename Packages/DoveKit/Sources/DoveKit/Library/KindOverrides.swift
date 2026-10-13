import Foundation

/// Item kinds Dove knows better than `ContentClassifier`: learned from an item's files once it was opened
/// (Real-Debrid and Offcloud list items without files), or set by the user ("Change type"). The user's choice wins.
///
/// Keyed by `ShelfItem.id`. Lives in the App Group container so the Files extension hides adult items too.
public struct KindOverrides: Codable, Sendable, Equatable {
    public var learned: [String: ContentKind] = [:]
    public var manual: [String: ContentKind] = [:]

    public init(learned: [String: ContentKind] = [:], manual: [String: ContentKind] = [:]) {
        self.learned = learned
        self.manual = manual
    }

    public func kind(for id: String) -> ContentKind? {
        manual[id] ?? learned[id]
    }

    /// The item's kind: the user's choice, then what its files said, then the classifier.
    public func kind(of item: LibraryItem) -> ContentKind {
        kind(for: ShelfItem.id(backend: item.backend, itemID: item.id))
            ?? ContentClassifier.classify(name: item.name, files: item.files)
    }

    public func shelfItem(_ item: LibraryItem) -> ShelfItem {
        ShelfItem(item: item, kind: kind(of: item))
    }

    enum CodingKeys: String, CodingKey { case learned, manual }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        learned = Self.kinds((try? c.decodeIfPresent([String: String].self, forKey: .learned)) ?? [:])
        manual = Self.kinds((try? c.decodeIfPresent([String: String].self, forKey: .manual)) ?? [:])
    }

    /// Kinds this build does not know are dropped instead of failing the whole file.
    private static func kinds(_ raw: [String: String]) -> [String: ContentKind] {
        raw.compactMapValues(ContentKind.init(rawValue:))
    }

    /// Reads the file; a bare `[id: kind]` dictionary (`library-kinds.json` before manual kinds) counts as learned.
    public static func load(from url: URL) -> KindOverrides? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
            return KindOverrides(learned: kinds(legacy))
        }
        return try? JSONDecoder().decode(KindOverrides.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
