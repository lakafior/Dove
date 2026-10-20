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

    struct Found: Equatable {
        /// Titles the model named and a search confirmed.
        var named: [MediaSummary]
        /// Titles TMDB tags with the description's words (with a TMDB key), the named ones left out.
        var byPlot: [MediaSummary]
        /// The words they were found by, for the footer.
        var plotWords: [String]
    }

    static func titles(
        for description: String,
        tmdb: TMDBMetadata?,
        search: @escaping @Sendable (String) async throws -> [MediaSummary]
    ) async throws -> Found {
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
            let named = await DescribedTitles.verify(candidates, search: search)
            logger.debug("Suggested \(candidates.map(\.title), privacy: .public); confirmed \(named.map(\.name), privacy: .public)")
            guard let tmdb else { return Found(named: named, byPlot: [], plotWords: []) }

            // The plot's own words, looked up as TMDB keywords: finds what the model cannot name.
            let query = try await LanguageModelSession(instructions: """
            You pick search words from a viewer's description of a movie or TV series. keywords: up to four single \
            nouns copied from the description that say what it is about (not names of people). kind: movie or \
            series when the description says so, else any. genres: from Action, Adventure, Animation, Comedy, Crime, \
            Documentary, Drama, Family, Fantasy, History, Horror, Mystery, Romance, Science Fiction, Thriller, War, \
            Western, only when the description makes one plain. Years only when it names a year or a decade.
            """)
            .respond(to: description, generating: PlotQuery.self, options: GenerationOptions(samplingMode: .greedy))
            .content
            let plot = DescribedTitles.Plot(
                description: description,
                type: query.kind == "movie" ? .movie : query.kind == "series" ? .series : nil,
                keywords: query.keywords,
                genres: query.genres,
                yearFrom: query.yearFrom,
                yearTo: query.yearTo
            )
            let namedIDs = Set(named.map(\.id))
            let byPlot = await DescribedTitles.discover(plot, tmdb: tmdb).filter { !namedIDs.contains($0.id) }
            logger.debug("Plot words \(plot.keywords, privacy: .public); found \(byPlot.map(\.name), privacy: .public)")
            return Found(named: named, byPlot: byPlot, plotWords: plot.keywords)
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

@available(iOS 26, *)
@Generable
struct PlotQuery {
    @Guide(description: "Single nouns copied from the description", .maximumCount(4))
    var keywords: [String]
    @Guide(description: "Movie or TV series", .anyOf(["movie", "series", "any"]))
    var kind: String
    @Guide(description: "Genres the description makes plain")
    var genres: [String]
    var yearFrom: Int?
    var yearTo: Int?
}
#endif
