import Foundation

/// "The show where office workers have their memories split" → titles that exist. The on-device model (in the app)
/// suggests up to `limit` candidates; each one counts only when a real search finds a title with the same name, of
/// the same type and year (within one) when the model gave them. A model's guess is never shown as a title.
public enum DescribedTitles {
    public static let limit = 5

    public struct Candidate: Sendable, Equatable {
        public var title: String
        public var year: Int?
        public var type: MediaType?

        public init(title: String, year: Int? = nil, type: MediaType? = nil) {
            self.title = title
            self.year = year
            self.type = type
        }
    }

    /// The search result that is this candidate, or nil. Names compare normalised and without a leading article
    /// ("The Office" is "Office"); no "closest result" fallback.
    public static func match(_ candidate: Candidate, in results: [MediaSummary]) -> MediaSummary? {
        let wanted = key(candidate.title)
        guard !wanted.isEmpty else { return nil }
        return results.first { media in
            if let type = candidate.type, media.type != type { return false }
            guard key(media.name) == wanted else { return false }
            guard let year = candidate.year else { return true }
            guard let found = media.releaseInfo.flatMap({ Int($0.prefix(4)) }) else { return true }
            return abs(found - year) <= 1
        }
    }

    /// Looks every candidate up (at once) and keeps the verified ones in the model's order, each title once.
    public static func verify(
        _ candidates: [Candidate],
        search: @escaping @Sendable (String) async throws -> [MediaSummary]
    ) async -> [MediaSummary] {
        let candidates = Array(candidates.prefix(limit))
        let found = await withTaskGroup(of: (Int, MediaSummary?).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    let results = (try? await search(candidate.title)) ?? []
                    return (index, match(candidate, in: results))
                }
            }
            var found: [Int: MediaSummary] = [:]
            for await (index, media) in group { found[index] = media }
            return found
        }
        var seen: Set<String> = []
        return candidates.indices.compactMap { found[$0] ?? nil }.filter { seen.insert($0.id).inserted }
    }

    static func key(_ title: String) -> String {
        var words = title.lowercased().split(whereSeparator: \.isWhitespace)
        if let first = words.first, ["the", "a", "an"].contains(first), words.count > 1 { words.removeFirst() }
        return MediaGuess.normalize(words.joined(separator: " "))
    }
}
