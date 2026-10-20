import Foundation
import Testing
@testable import DoveKit

struct DescribedTitlesTests {
    private func media(_ id: String, _ name: String, _ year: String?, _ type: MediaType = .series) -> MediaSummary {
        MediaSummary(id: id, type: type, name: name, releaseInfo: year)
    }

    @Test func onlyTheSameNameTypeAndYearCount() {
        let results = [media("tmdb:2", "Severance Pay", "2010", .movie), media("tmdb:1", "Severance", "2022")]
        #expect(DescribedTitles.match(.init(title: "Severance", year: 2022, type: .series), in: results)?.id == "tmdb:1")
        #expect(DescribedTitles.match(.init(title: "Severance", year: 2023), in: results)?.id == "tmdb:1")
        #expect(DescribedTitles.match(.init(title: "Severance", year: 2015), in: results) == nil)
        #expect(DescribedTitles.match(.init(title: "Severance", type: .movie), in: results) == nil)
        // No "closest result": a title that is not there is not shown.
        #expect(DescribedTitles.match(.init(title: "Memory Split Office"), in: results) == nil)
    }

    @Test func leadingArticleAndPunctuationDoNotMatter() {
        let results = [media("tmdb:3", "The Office", "2005")]
        #expect(DescribedTitles.match(.init(title: "Office"), in: results)?.id == "tmdb:3")
        #expect(DescribedTitles.match(.init(title: "the office!"), in: results)?.id == "tmdb:3")
    }

    @Test func verifyKeepsTheModelsOrderAndDropsInventions() async {
        let catalog: [String: [MediaSummary]] = [
            "Severance": [media("tmdb:1", "Severance", "2022")],
            "Made Up Show": [media("tmdb:9", "Something Else", "2020")],
            "Dark": [media("tmdb:4", "Dark", "2017")],
        ]
        let found = await DescribedTitles.verify([
            .init(title: "Made Up Show"), .init(title: "Severance", year: 2022), .init(title: "Dark"), .init(title: "Severance"),
        ]) { catalog[$0] ?? [] }
        #expect(found.map(\.id) == ["tmdb:1", "tmdb:4"])
    }

    @Test func plotKeepsOnlyTheDescriptionsOwnWords() {
        let plot = DescribedTitles.Plot(
            description: "the show where office workers have their memories split",
            type: .series, keywords: ["office", "show", "memories", "dystopia", "workers", "split", "office"],
            genres: ["Drama"], yearFrom: 2020, yearTo: nil
        )
        #expect(plot.keywords == ["office", "memories", "workers", "split"])
        #expect(plot.years == nil, "no year in the words")
    }

    @Test func discoverRanksTitlesByTheWordsTheyAnswerTo() async throws {
        let transport = MockTransport()
        await transport.stub("3/search/keyword", queryContains: "query=office", json: #"{"results":[{"id":1}]}"#)
        await transport.stub("3/search/keyword", queryContains: "query=memories", json: #"{"results":[{"id":2}]}"#)
        await transport.stub("3/discover/tv", queryContains: "with_keywords=1", json: #"{"results":[{"id":10,"name":"The Office","first_air_date":"2005-03-24"},{"id":20,"name":"Severance","first_air_date":"2022-02-17"}]}"#)
        await transport.stub("3/discover/tv", queryContains: "with_keywords=2", json: #"{"results":[{"id":20,"name":"Severance","first_air_date":"2022-02-17"},{"id":30,"name":"Dark","first_air_date":"2017-12-01"}]}"#)
        let tmdb = TMDBMetadata(key: "0123456789abcdef0123456789abcdef", transport: transport)
        let plot = DescribedTitles.Plot(description: "office workers memories", type: .series, keywords: ["office", "memories"],
                                        genres: ["Drama"], yearFrom: nil, yearTo: nil)

        let found = await DescribedTitles.discover(plot, tmdb: tmdb)

        #expect(found.map(\.name) == ["Severance", "The Office", "Dark"])
        let discover = try #require(await transport.requests.first { $0.url!.path.hasSuffix("discover/tv") })
        #expect(discover.url!.query!.contains("with_genres=18"))
        #expect(discover.url!.query!.contains("sort_by=popularity.desc"))
    }
}
