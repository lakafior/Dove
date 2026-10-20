import Foundation
import Testing
@testable import DoveKit

struct LibraryRequestTests {
    private func title(_ id: String, _ name: String, year: Int, type: MediaType, items: [(String, BackendID)]) -> LibraryTitle {
        LibraryTitle(
            id: id,
            guess: MediaGuess(title: name, year: year, type: type),
            media: MediaSummary(id: "tt\(id)", type: type, name: name, releaseInfo: String(year)),
            items: items.map { ShelfItem(item: LibraryItem(id: $0.0, backend: $0.1, name: $0.0, status: .ready)) }
        )
    }

    private var titles: [LibraryTitle] {
        [
            title("1", "Twin Peaks", year: 1990, type: .series, items: [("Twin.Peaks.S01.2160p.WEB-DL", .realDebrid), ("Twin.Peaks.S01.720p.HDTV", .offcloud)]),
            title("2", "The Thing", year: 1982, type: .movie, items: [("The.Thing.1982.2160p.UHD.BluRay", .realDebrid)]),
            title("3", "Miami Vice", year: 1984, type: .series, items: [("Miami.Vice.S01.1080p.BluRay", .torBox)]),
            title("4", "Severance", year: 2022, type: .series, items: [("Severance.S01.2160p.ATVP.WEB-DL", .torBox)]),
        ]
    }

    @Test func seriesFromTheEightiesIn4KOnRealDebrid() {
        let request = LibraryRequest(text: "series from the 80s in 4K on Real-Debrid", kind: "series", yearFrom: 1980, yearTo: 1989,
                                     resolutions: ["4K"], services: ["Real-Debrid"], status: nil, words: nil)
        #expect(request.category == .series)
        #expect(request.years == 1980...1989)
        #expect(request.resolutions == ["2160p"])
        #expect(request.backends == [.realDebrid])
        #expect(request.apply(to: titles).isEmpty, "Twin Peaks is 1990")

        let movies = LibraryRequest(text: "movies from the 80s in 4K", kind: "movies", yearFrom: 1980, yearTo: 1989,
                                    resolutions: ["2160p"], services: [], status: nil, words: nil)
        let found = movies.apply(to: titles)
        #expect(found.map(\.name) == ["The Thing"])
        #expect(movies.summary == "Movies · 1980–1989 · 2160p")
    }

    @Test func itemsThatDoNotFitAreTrimmed() {
        let request = LibraryRequest(text: "everything in 2160p", kind: nil, yearFrom: nil, yearTo: nil,
                                     resolutions: ["2160p"], services: [], status: nil, words: nil)
        let peaks = request.apply(to: titles).first { $0.name == "Twin Peaks" }
        #expect(peaks?.items.map(\.item.id) == ["Twin.Peaks.S01.2160p.WEB-DL"])
    }

    @Test func valuesTheWordsDoNotNameAreDropped() {
        // The model guessed a kind, years, a service and title words from "horror": none of them are in the words.
        let request = LibraryRequest(text: "horror in 4K", kind: "movies", yearFrom: 1980, yearTo: 1989,
                                     resolutions: ["2160p", "1080p"], services: ["TorBox"], status: "ready", words: "Thing")
        #expect(request.category == nil)
        #expect(request.years == nil)
        #expect(request.resolutions == ["2160p"])
        #expect(request.backends.isEmpty)
        #expect(request.status == nil)
        #expect(request.words == nil)
        #expect(request.ignoresGenre)
    }

    @Test func titleWordsAndOpenYears() {
        let request = LibraryRequest(text: "anything with miami since 1983", kind: nil, yearFrom: 1983, yearTo: nil,
                                     resolutions: [], services: [], status: nil, words: "miami")
        #expect(request.apply(to: titles).map(\.name) == ["Miami Vice"])
        #expect(request.summary == "from 1983 · \u{201C}miami\u{201D}")
        #expect(LibraryRequest(text: "x").isEmpty)
    }

    @Test func genreWordsAreNotTitleWords() {
        let request = LibraryRequest(text: "Horror movies from the 2000s", kind: "movies", yearFrom: 2000, yearTo: 2009,
                                     resolutions: [], services: [], status: nil, words: "Horror")
        #expect(request.words == nil)
        #expect(request.category == .movies)
        #expect(request.years == 2000...2009)
        #expect(request.ignoresGenre)
    }
}
