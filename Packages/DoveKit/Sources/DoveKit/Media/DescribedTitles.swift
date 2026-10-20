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

    // MARK: - By plot

    /// What a description says about a title when the model cannot name one: words of its plot, its kind, genres
    /// and years. Words count only when they are in the description (the model may not add its own).
    public struct Plot: Sendable, Equatable {
        public var type: MediaType?
        public var keywords: [String]
        public var genres: [String]
        public var years: ClosedRange<Int>?

        /// Words that say what kind of title it is, not what happens in it ("show" is a TMDB keyword of its own).
        static let notPlot: Set<String> = Set(LibraryRequest.kindWords.values.flatMap { $0 } + LibraryRequest.genreWords
            + ["episode", "episodes", "season", "seasons", "character", "characters", "story", "plot", "thing", "people"])

        public init(description: String, type: MediaType?, keywords: [String], genres: [String], yearFrom: Int?, yearTo: Int?) {
            self.type = type
            var seen: Set<String> = []
            self.keywords = keywords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { $0.count >= 3 && description.localizedCaseInsensitiveContains($0) && !Self.notPlot.contains($0) && seen.insert($0).inserted }
                .prefix(4)
                .map { $0 }
            self.genres = genres
            if LibraryRequest.namesYears(description), let from = yearFrom ?? yearTo, let to = yearTo ?? yearFrom {
                years = min(from, to)...max(from, to)
            }
        }
    }

    /// Titles TMDB tags with the plot's words: one discover per word (movies and series unless the kind is
    /// known), ranked by how many words a title answers to, then by popularity. Real titles only, by construction.
    public static func discover(_ plot: Plot, tmdb: TMDBMetadata, limit: Int = 8) async -> [MediaSummary] {
        let types: [MediaType] = plot.type.map { [$0] } ?? [.series, .movie]
        var ids: [Int] = []
        for word in plot.keywords {
            if let id = try? await tmdb.keywordID(word) { ids.append(id) }
        }
        guard !ids.isEmpty else { return [] }
        var score: [String: (media: MediaSummary, hits: Int, rank: Int)] = [:]
        for type in types {
            let genres = TMDBMetadata.genreIDs(plot.genres, for: type)
            for id in ids {
                let found = (try? await tmdb.discover(type, keyword: id, genres: genres, years: plot.years)) ?? []
                for (rank, media) in found.enumerated() {
                    let current = score[media.id]
                    score[media.id] = (media, (current?.hits ?? 0) + 1, min(current?.rank ?? .max, rank))
                }
            }
        }
        return score.values
            .sorted { $0.hits != $1.hits ? $0.hits > $1.hits : $0.rank < $1.rank }
            .prefix(limit)
            .map(\.media)
    }
}
