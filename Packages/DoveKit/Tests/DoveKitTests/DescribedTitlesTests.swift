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
}
