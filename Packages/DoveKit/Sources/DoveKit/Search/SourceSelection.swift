import Foundation

/// Which sources each search category asks, so indexers with daily limits are spent only where they help
/// (e.g. books through one indexer, movies through all). Stored as what is switched off, so a new indexer or
/// addon starts on everywhere. Applies on top of each indexer's own on/off switch in Settings.
public struct SourceSelection: Codable, Sendable, Equatable {
    /// The Stremio addons as one source (Movies & TV only).
    public static let addons = "addons"

    /// Source IDs switched off, by `SearchCategory.rawValue` (string keys decode leniently across builds).
    private var disabled: [String: Set<String>] = [:]

    public init() {}

    public func isOn(_ source: String, in category: SearchCategory) -> Bool {
        !(disabled[category.rawValue]?.contains(source) ?? false)
    }

    public mutating func set(_ source: String, on: Bool, in category: SearchCategory) {
        var off = disabled[category.rawValue] ?? []
        if on { off.remove(source) } else { off.insert(source) }
        disabled[category.rawValue] = off.isEmpty ? nil : off
    }

    public func asksAddons(in category: SearchCategory) -> Bool {
        category.usesAddons && isOn(Self.addons, in: category)
    }

    /// Enabled indexers this category asks.
    public func indexerIDs(in category: SearchCategory, from indexers: [NewznabIndexer]) -> Set<String> {
        Set(indexers.filter { $0.enabled && isOn($0.id, in: category) }.map(\.id))
    }

    /// How many of the category's sources are on, and how many there are: "Sources 2/3".
    public func count(in category: SearchCategory, indexers: [NewznabIndexer]) -> (on: Int, total: Int) {
        let enabled = indexers.filter(\.enabled)
        var on = indexerIDs(in: category, from: enabled).count
        var total = enabled.count
        if category.usesAddons {
            total += 1
            if asksAddons(in: category) { on += 1 }
        }
        return (on, total)
    }

    enum CodingKeys: String, CodingKey { case disabled }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        disabled = (try? c.decodeIfPresent([String: Set<String>].self, forKey: .disabled)) ?? [:]
    }
}
