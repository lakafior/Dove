import DoveKit
import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

/// "The show where office workers have their memories split" → titles: the on-device model suggests a few, and
/// `DescribedTitles.verify` keeps only those a real search finds (TMDB or the metadata addons). It knows well-known
/// titles and misses obscure plots; when nothing checks out, Dove says so instead of showing a guess.
enum DescribedSearch {
    private static let logger = Logger(subsystem: "net.smigi.dove", category: "described-search")

    static func titles(for description: String, search: @escaping @Sendable (String) async throws -> [MediaSummary]) async throws -> [MediaSummary] {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            let session = LanguageModelSession(instructions: """
            You name real, released movies and TV series that fit a viewer's description of one they remember. \
            Give at most \(DescribedTitles.limit), most likely first, under their original English titles, with the \
            year they came out. Only name titles you are confident exist; give fewer rather than invent one.
            """)
            // Greedy: the same words give the same titles (sampling made a second try answer differently).
            let answer = try await session.respond(
                to: description,
                generating: TitleSuggestions.self,
                options: GenerationOptions(samplingMode: .greedy)
            ).content
            let candidates = answer.titles.map {
                DescribedTitles.Candidate(
                    title: $0.title,
                    year: $0.year.flatMap { (1880...2100).contains($0) ? $0 : nil },
                    type: $0.kind == "series" ? .series : $0.kind == "movie" ? .movie : nil
                )
            }
            let found = await DescribedTitles.verify(candidates, search: search)
            logger.debug("Suggested \(candidates.map(\.title), privacy: .public); confirmed \(found.map(\.name), privacy: .public)")
            return found
        }
        #endif
        throw DescribedFilter.Failure.unavailable
    }
}

#if canImport(FoundationModels)
@available(iOS 26, *)
@Generable
struct TitleSuggestions {
    @Generable
    struct Title {
        @Guide(description: "The title as released, in English")
        var title: String
        @Guide(description: "Year of release (first episode for a series)")
        var year: Int?
        @Guide(description: "Movie or TV series", .anyOf(["movie", "series"]))
        var kind: String
    }

    @Guide(description: "Titles that fit the description, most likely first", .maximumCount(5))
    var titles: [Title]
}
#endif
