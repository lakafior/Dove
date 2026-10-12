import Foundation
import Testing
@testable import DoveKit

private func item(_ name: String, _ backend: BackendID, id: String, status: LibraryItem.Status = .ready, added: TimeInterval = 0) -> ShelfItem {
    ShelfItem(item: LibraryItem(id: id, backend: backend, name: name, size: 10, status: status, addedAt: Date(timeIntervalSince1970: added)))
}

struct LibraryMatcherTests {
    private let dune2021 = MediaSummary(id: "tt1160419", type: .movie, name: "Dune", releaseInfo: "2021")
    private let dune1984 = MediaSummary(id: "tt0087182", type: .movie, name: "Dune", releaseInfo: "1984")
    private let duneSeries = MediaSummary(id: "tt0142032", type: .series, name: "Dune", releaseInfo: "2000")

    @Test func titleAndYearWin() {
        let guess = ReleaseParser.guess("Dune.1984.1080p.BluRay")
        #expect(LibraryMatcher.best([dune2021, dune1984, duneSeries], for: guess) == dune1984)
    }

    @Test func typeMustMatch() {
        let guess = ReleaseParser.guess("Dune.S01E01.1080p")
        #expect(LibraryMatcher.best([dune2021, duneSeries], for: guess) == duneSeries)
        #expect(LibraryMatcher.best([dune2021], for: guess) == nil)
    }

    @Test func closeTitleWithSameYear() {
        let partOne = MediaSummary(id: "tt1160419", type: .movie, name: "Dune: Part One", releaseInfo: "2021")
        let guess = ReleaseParser.guess("Dune Part One 2021 2160p UHD BDRip")
        #expect(LibraryMatcher.best([dune1984, partOne], for: guess) == partOne)
    }

    @Test func matchMissingSearchesOnceAndRemembers() async {
        let store = MatchStore(fileURL: nil)
        let counter = Counter()
        let guesses = [
            ReleaseParser.guess("Dune.2021.2160p").key: ReleaseParser.guess("Dune.2021.2160p"),
            ReleaseParser.guess("Nothing.Here.2020.1080p").key: ReleaseParser.guess("Nothing.Here.2020.1080p"),
        ]
        let search: @Sendable (String, MediaType) async throws -> [MediaSummary] = { query, _ in
            await counter.bump()
            return query == "Dune" ? [MediaSummary(id: "tt1160419", type: .movie, name: "Dune", releaseInfo: "2021")] : []
        }

        let first = await LibraryMatcher.matchMissing(guesses, store: store, search: search)
        let second = await LibraryMatcher.matchMissing(guesses, store: store, search: search)

        #expect(first == 2)
        #expect(second == 0)
        #expect(await counter.value == 2)
        #expect(await store.entry(for: ReleaseParser.guess("Dune.2021.2160p").key)?.media?.id == "tt1160419")
    }

    @Test func manualChoiceSurvivesAndPersists() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "dove-matches-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = MatchStore(fileURL: file)
        await store.set(.manual(dune1984), for: "dune|2021|movie")
        #expect(await store.needsLookup("dune|2021|movie") == false)

        let reopened = MatchStore(fileURL: file)
        #expect(await reopened.entry(for: "dune|2021|movie") == .manual(dune1984))
    }

    @Test func failedSearchIsRetriedNextTime() async {
        let store = MatchStore(fileURL: nil)
        let guess = ReleaseParser.guess("Dune.2021.2160p")
        await LibraryMatcher.matchMissing([guess.key: guess], store: store) { _, _ in throw URLError(.notConnectedToInternet) }
        #expect(await store.needsLookup(guess.key))
    }
}

private actor Counter {
    var value = 0
    func bump() { value += 1 }
}

struct LibraryShelfTests {
    private let items = [
        item("Severance.S01.1080p.BluRay.REMUX", .torBox, id: "torrent:1", added: 300),
        item("Severance.S02E03.2160p.ATVP.WEB-DL", .offcloud, id: "cloud:a", status: .downloading(progress: 0.5), added: 200),
        item("Dune.2021.2160p.WEB-DL", .realDebrid, id: "torrent:R", added: 100),
        item("Dune.Part.One.2021.2160p.BluRay.REMUX", .torBox, id: "torrent:2", status: .failed(reason: "dead"), added: 50),
    ]

    @Test func groupsByGuessWithoutMatches() {
        let titles = LibraryShelf.titles(items, matches: [:])
        #expect(titles.map(\.name) == ["Severance", "Dune", "Dune Part One"])
        let severance = titles[0]
        #expect(severance.backends == [.offcloud, .torBox])
        #expect(severance.status == .active)
        #expect(severance.seasons.map(\.season) == [1, 2])
    }

    @Test func matchedReleasesOfOneTitleMerge() {
        let dune = MediaSummary(id: "tt1160419", type: .movie, name: "Dune", releaseInfo: "2021")
        let matches = [
            ReleaseParser.guess("Dune.2021.2160p.WEB-DL").key: dune,
            ReleaseParser.guess("Dune.Part.One.2021.2160p.BluRay.REMUX").key: dune,
        ]
        let titles = LibraryShelf.titles(items, matches: matches)
        #expect(titles.count == 2)
        let merged = try? #require(titles.first { $0.media == dune })
        #expect(merged?.items.count == 2)
        #expect(merged?.status == .failed)
        #expect(merged?.backends == [.realDebrid, .torBox])
    }

    @Test func filterByBackendTrimsTitles() {
        var filter = LibraryFilter()
        filter.backends = [.torBox]
        let titles = filter.apply(to: LibraryShelf.titles(items, matches: [:]))
        #expect(titles.map(\.name) == ["Severance", "Dune Part One"])
        #expect(titles[0].items.count == 1)
    }

    @Test func filterByTypeStatusAndQuery() {
        var filter = LibraryFilter()
        filter.category = .movies
        #expect(filter.apply(to: items).count == 2)
        filter.status = .ready
        #expect(filter.apply(to: items).map(\.item.id) == ["torrent:R"])
        filter = LibraryFilter()
        filter.query = "sever"
        #expect(filter.apply(to: items).count == 2)
    }

    @Test func loaderMergesBackendsAndReportsFailures() async {
        let good = MockTransport()
        await good.stub("torrents/mylist", body: (try? Fixture.data("torbox_torrents_mylist")) ?? Data())
        await good.stub("webdl/mylist", body: (try? Fixture.data("torbox_webdl_mylist")) ?? Data())
        let bad = MockTransport()
        await bad.stub("cloud/history", status: 401, json: #"{"error":"NOAUTH"}"#)

        let result = await LibraryLoader.load([
            TorBoxBackend(apiKey: "k", transport: good),
            OffcloudBackend(apiKey: "k", transport: bad),
        ])

        #expect(result.items.count == 4)
        #expect(result.failures == ["Offcloud: Invalid or expired API key."])
    }
}
