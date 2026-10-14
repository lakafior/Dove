import DoveKit
import Foundation
import Observation

/// What the home screen shows besides the library: recent searches (this device only) and, with a TMDB key,
/// this week's trending titles, fetched at most twice a day.
@MainActor
@Observable
final class HomeModel {
    private(set) var recentSearches: [RecentSearch] = []
    private(set) var trending: [MediaSummary] = []

    struct RecentSearch: Codable, Hashable, Identifiable {
        var text: String
        var scope: SearchScope
        var id: String { "\(scope.rawValue):\(text.lowercased())" }
    }

    private static let recentKey = "recentSearches.v1"
    private static let recentLimit = 12
    private static let trendingURL = URL.cachesDirectory.appending(path: "Dove/trending.json")
    private static let trendingMaxAge: TimeInterval = 12 * 60 * 60

    private struct TrendingCache: Codable {
        var savedAt: Date
        var items: [MediaSummary]
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.recentKey),
           let saved = try? JSONDecoder().decode([RecentSearch].self, from: data) {
            recentSearches = saved
        }
        if let data = try? Data(contentsOf: Self.trendingURL),
           let cache = try? JSONDecoder().decode(TrendingCache.self, from: data) {
            trending = cache.items
        }
    }

    /// Newest first; the same words in the same scope move to the top instead of repeating.
    func remember(_ text: String, scope: SearchScope) {
        let entry = RecentSearch(text: text.trimmingCharacters(in: .whitespacesAndNewlines), scope: scope)
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

    /// TMDB's weekly list; without a key there is none (Dove has no content of its own). The cached list stays
    /// when TMDB does not answer.
    func loadTrending(using tmdb: TMDBMetadata?) async {
        guard let tmdb else {
            trending = []
            return
        }
        if let data = try? Data(contentsOf: Self.trendingURL),
           let cache = try? JSONDecoder().decode(TrendingCache.self, from: data),
           Date.now.timeIntervalSince(cache.savedAt) < Self.trendingMaxAge,
           !cache.items.isEmpty {
            trending = cache.items
            return
        }
        guard let fresh = try? await tmdb.trending(), !fresh.isEmpty else { return }
        trending = fresh
        try? FileManager.default.createDirectory(at: Self.trendingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(TrendingCache(savedAt: .now, items: fresh)).write(to: Self.trendingURL, options: .atomic)
    }
}
