import DoveKit
import Foundation
import Observation

/// What the home screen keeps besides the library: recent searches, on this device only.
@MainActor
@Observable
final class HomeModel {
    private(set) var recentSearches: [RecentSearch] = []

    struct RecentSearch: Codable, Hashable, Identifiable {
        var text: String
        var category: SearchCategory
        var id: String { "\(category.rawValue):\(text.lowercased())" }

        /// Saved before categories as `scope` (`media`/`other`); `SearchCategory` reads `other` as All.
        enum CodingKeys: String, CodingKey {
            case text
            case category = "scope"
        }
    }

    private static let recentKey = "recentSearches.v1"
    private static let recentLimit = 12

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.recentKey),
           let saved = try? JSONDecoder().decode([RecentSearch].self, from: data) {
            recentSearches = saved
        }
    }

    /// Newest first; the same words in the same category move to the top instead of repeating.
    func remember(_ text: String, category: SearchCategory) {
        let entry = RecentSearch(text: text.trimmingCharacters(in: .whitespacesAndNewlines), category: category)
        guard !entry.text.isEmpty else { return }
        recentSearches.removeAll { $0.id == entry.id }
        recentSearches.insert(entry, at: 0)
        recentSearches = Array(recentSearches.prefix(Self.recentLimit))
        saveRecent()
    }

    func forget(_ search: RecentSearch) {
        recentSearches.removeAll { $0.id == search.id }
        saveRecent()
    }

    func forgetAll() {
        recentSearches = []
        saveRecent()
    }

    private func saveRecent() {
        UserDefaults.standard.set(try? JSONEncoder().encode(recentSearches), forKey: Self.recentKey)
    }
}
