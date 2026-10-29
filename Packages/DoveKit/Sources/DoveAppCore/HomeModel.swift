import DoveKit
import Foundation
import Observation

/// What the home screen keeps besides the library: recent searches, on this device only.
@MainActor
@Observable
public final class HomeModel {
    public private(set) var recentSearches: [RecentSearch] = []

    public struct RecentSearch: Codable, Hashable, Identifiable {
        public var text: String
        public var category: SearchCategory
        public var id: String { "\(category.rawValue):\(text.lowercased())" }

        /// Saved before categories as `scope` (`media`/`other`); `SearchCategory` reads `other` as All.
        public enum CodingKeys: String, CodingKey {
            case text
            case category = "scope"
        }
    }

    private static let recentKey = "recentSearches.v1"
    private static let recentLimit = 12

    public init() {
        if let data = DoveStorage.defaults.data(forKey: Self.recentKey),
           let saved = try? JSONDecoder().decode([RecentSearch].self, from: data) {
            recentSearches = saved
        }
    }

    /// Newest first; the same words in the same category move to the top instead of repeating.
    public func remember(_ text: String, category: SearchCategory) {
        let entry = RecentSearch(text: text.trimmingCharacters(in: .whitespacesAndNewlines), category: category)
        guard !entry.text.isEmpty else { return }
        recentSearches.removeAll { $0.id == entry.id }
        recentSearches.insert(entry, at: 0)
        recentSearches = Array(recentSearches.prefix(Self.recentLimit))
        saveRecent()
    }

    public func forget(_ search: RecentSearch) {
        recentSearches.removeAll { $0.id == search.id }
        saveRecent()
    }

    public func forgetAll() {
        recentSearches = []
        saveRecent()
    }

    private func saveRecent() {
        DoveStorage.defaults.set(try? JSONEncoder().encode(recentSearches), forKey: Self.recentKey)
    }
}
