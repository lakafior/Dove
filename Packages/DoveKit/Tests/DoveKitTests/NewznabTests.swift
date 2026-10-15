import Foundation
import Testing
@testable import DoveKit

struct NewznabTests {
    private func indexer(_ name: String = "Geek", host: String = "indexer.example", limit: Int? = nil) -> NewznabIndexer {
        NewznabIndexer(id: name, name: name, url: URL(string: "https://\(host)")!, apiKey: "KEY-\(name)", dailyLimit: limit)
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    private func stubIndexer(_ transport: MockTransport) async throws {
        await transport.stub("/api", queryContains: "t=caps", body: try Fixture.data("newznab_caps", extension: "xml"), contentType: "application/xml")
        await transport.stub("/api", queryContains: "t=movie", body: try Fixture.data("newznab_movie", extension: "xml"), contentType: "application/xml")
    }

    @Test func queriesFromStreamIDs() {
        #expect(NewznabQuery(type: .movie, id: "tt123", title: "A", wholeSeason: false) == .movie(imdbID: "tt123", title: "A"))
        #expect(NewznabQuery(type: .series, id: "tt9:2:5", title: "S", wholeSeason: false) == .episode(imdbID: "tt9", season: 2, episode: 5, title: "S"))
        #expect(NewznabQuery(type: .series, id: "tt9:2:1", title: nil, wholeSeason: true) == .season(imdbID: "tt9", season: 2, title: nil))
        #expect(NewznabQuery(type: .series, id: "kitsu:1:1", title: "S", wholeSeason: false) == nil)
    }

    @Test func parametersPreferIMDbAndFallBackToTheTitle() {
        let episode = NewznabQuery.episode(imdbID: "tt0903747", season: 2, episode: 5, title: "Breaking Bad")
        #expect(episode.parameters(supported: ["q", "imdbid", "season", "ep"])?.map(\.name) == ["imdbid", "cat", "season", "ep"])
        #expect(episode.parameters(supported: ["q", "imdbid"])?.first?.value == "0903747")
        #expect(episode.parameters(supported: ["q", "tvdbid", "season", "ep"])?.first == URLQueryItem(name: "q", value: "Breaking Bad"))
        #expect(NewznabQuery.season(imdbID: "tt1", season: 3, title: nil).parameters(supported: ["q"]) == nil)
    }

    @Test func moviesAndSeriesAskForTheirCategoryAndTextQueriesForThePickedOne() {
        let cat = { (query: NewznabQuery, params: Set<String>) in
            query.parameters(supported: params)?.first { $0.name == "cat" }?.value
        }
        #expect(cat(.movie(imdbID: "tt1", title: "A"), ["imdbid"]) == "2000")
        #expect(cat(.season(imdbID: "tt1", season: 1, title: "A"), ["imdbid", "season"]) == "5000")
        #expect(cat(.text("photoshop", category: .software), ["q"]) == "4000")
        #expect(cat(.text("anything", category: .all), ["q"]) == nil)
        #expect(cat(.text("project hail mary", category: .audiobooks), ["q"]) == "3030")

        let text = NewznabQuery.text("Some Album", category: .music)
        #expect(text.function == "search")
        #expect(text.parameters(supported: NewznabCaps(movieParams: [], tvParams: []).params(for: text))?.first
            == URLQueryItem(name: "q", value: "Some Album"))
    }

    @Test func resultsFromOtherCategoriesAreDroppedFromMovieSearches() async throws {
        let transport = MockTransport()
        await transport.stub("/api", queryContains: "t=movie", body: try Fixture.data("newznab_mixed", extension: "xml"), contentType: "application/xml")
        await transport.stub("/api", queryContains: "t=search", body: try Fixture.data("newznab_mixed", extension: "xml"), contentType: "application/xml")
        let client = NewznabClient(indexer: indexer(), transport: transport)
        let caps = NewznabCaps(movieParams: ["q", "imdbid"], tvParams: ["q"], maxLimit: 100)

        let movie = try #require(try await client.search(.movie(imdbID: "tt1", title: "Some Movie"), caps: caps))
        #expect(movie.map(\.title) == ["Some.Movie.2023.1080p.BluRay.x264-GRP", "Some.Movie.Unlabelled"], "uncategorized results stay")
        #expect(movie[0].category == 2040)

        let software = try #require(try await client.search(.text("Some Movie", category: .software), caps: caps))
        #expect(software.map(\.title) == ["Some.Movie.Game.v1.2-CODEX", "Some.Movie.Unlabelled"])
        #expect(query(try #require(await transport.requests.last))["cat"] == "4000")

        // A subcategory keeps only itself: music (3040) is not an audiobook (3030).
        let audiobooks = try #require(try await client.search(.text("Some Movie", category: .audiobooks), caps: caps))
        #expect(audiobooks.map(\.title) == ["Some.Movie.Unlabelled"])
        let music = try #require(try await client.search(.text("Some Movie", category: .music), caps: caps))
        #expect(music.map(\.category) == [3040, nil])

        let all = try #require(try await client.search(.text("Some Movie", category: .all), caps: caps))
        #expect(all.count == 4)
        #expect(all.compactMap(\.category).map(ContentKind.init(newznabCategory:)) == [.video, .software, .music])
    }

    @Test func normalizesPastedURLs() {
        #expect(NewznabIndexer.normalized(url: "api.nzbgeek.info")?.url.absoluteString == "https://api.nzbgeek.info")
        let full = NewznabIndexer.normalized(url: "https://x.example/sub/api?apikey=abc")
        #expect(full?.url.absoluteString == "https://x.example/sub")
        #expect(full?.apiPath == "/api")
        #expect(NewznabIndexer.normalized(url: "ftp://x") == nil)
    }

    @Test func capsAndSearchParse() async throws {
        let transport = MockTransport()
        try await stubIndexer(transport)
        let client = NewznabClient(indexer: indexer(), transport: transport)

        let caps = try await client.caps()
        #expect(caps.movieParams == ["q", "imdbid"])
        #expect(caps.tvParams.contains("tvdbid"))
        #expect(caps.maxLimit == 100)

        let found = try #require(try await client.search(.movie(imdbID: "tt15398776", title: "Some Movie"), caps: caps))
        #expect(found.count == 2)
        #expect(found[0].kind == .usenet)
        #expect(found[0].title == "Some.Movie.2023.2160p.UHD.BluRay.REMUX.DV.HEVC-GRP")
        #expect(found[0].size == 61_000_000_000, "the size attribute wins over the enclosure length")
        #expect(found[1].size == 8_000_000_000)
        #expect(found[0].nzbURL?.absoluteString == "https://indexer.example/api?t=get&id=aaa&apikey=KEY")
        #expect(found[0].label == "Geek")
        #expect(found[0].service == nil, "an indexer finds NZBs; the service is set when routed")
        #expect(found[0].librarySource == .nzbURL(found[0].nzbURL!))

        let search = try #require(await transport.requests.last)
        #expect(query(search)["imdbid"] == "15398776")
        #expect(query(search)["t"] == "movie")
        #expect(query(search)["apikey"] == "KEY-Geek")
        #expect(query(search)["extended"] == "1")
    }

    @Test func errorDocumentsMapToReasons() {
        let auth = NewznabParser.parse(Data(#"<?xml version="1.0"?><error code="100" description="Incorrect user credentials"/>"#.utf8))
        #expect(auth.error == .unauthorized("Incorrect user credentials"))
        let limit = NewznabParser.parse(Data(#"<error code="500" description="Request limit reached"/>"#.utf8))
        #expect(limit.error == .limitReached("Request limit reached"))
        let html = NewznabParser.parse(Data("<html><body>Login</body></html>".utf8))
        #expect(!html.isNewznab)
    }

    @Test func searchCachesCapsAndResultsAndCountsHits() async throws {
        let transport = MockTransport()
        try await stubIndexer(transport)
        let search = NewznabSearch(indexers: [indexer()], stateURL: nil, transport: transport)
        let movie = NewznabQuery.movie(imdbID: "tt1", title: nil)

        let first = await search.search(movie)
        let second = await search.search(movie)
        _ = await search.search(.movie(imdbID: "tt2", title: nil))

        #expect(first.candidates.count == 2)
        #expect(second.candidates.count == 2)
        let requests = await transport.requests.map(query)
        #expect(requests.map { $0["t"] } == ["caps", "movie", "movie"], "caps once, the repeat from the cache")
        #expect(await search.usage(of: indexer()).hits == 3)
    }

    @Test func searchAsksOnlyThePickedIndexers() async throws {
        let transport = MockTransport()
        try await stubIndexer(transport)
        let search = NewznabSearch(indexers: [indexer("Geek"), indexer("Slug")], stateURL: nil, transport: transport)
        let movie = NewznabQuery.movie(imdbID: "tt1", title: nil)

        let none = await search.search(movie, only: [])
        #expect(none.candidates.isEmpty)
        #expect(await transport.requests.isEmpty, "no source picked: no hits spent")

        _ = await search.search(movie, only: ["Slug"])
        let usages = await search.usages()
        #expect(usages["Geek"]?.hits == 0)
        #expect(usages["Slug"]?.hits == 2)
    }

    @Test func dailyLimitAndLimitErrorsSkipTheIndexer() async throws {
        let transport = MockTransport()
        try await stubIndexer(transport)
        let limited = indexer(limit: 2)
        let search = NewznabSearch(indexers: [limited], stateURL: nil, transport: transport)

        _ = await search.search(.movie(imdbID: "tt1", title: nil))
        let skipped = await search.search(.movie(imdbID: "tt2", title: nil))

        #expect(skipped.candidates.isEmpty)
        #expect(skipped.failures == ["Geek: used 2 of 2 daily API hits, back tomorrow"])

        let refusing = MockTransport()
        await refusing.stub("/api", body: Data(#"<error code="500" description="Request limit reached"/>"#.utf8))
        let other = NewznabSearch(indexers: [indexer("Slug")], stateURL: nil, transport: refusing)
        _ = await other.search(.movie(imdbID: "tt1", title: nil))
        let after = await other.search(.movie(imdbID: "tt2", title: nil))
        #expect(after.failures == ["Slug: daily limit reached, back tomorrow"])
        #expect(await refusing.requests.count == 1)
    }

    @Test func oneFailingIndexerDoesNotHideTheOthers() async throws {
        let transport = MockTransport()
        try await stubIndexer(transport)
        let broken = NewznabIndexer(id: "b", name: "Broken", url: URL(string: "https://broken.example/x")!, apiKey: "x")
        await transport.stub("x/api", queryContains: "t=", body: Data("<html>Login</html>".utf8), contentType: "text/html")
        let search = NewznabSearch(indexers: [indexer(), broken], stateURL: nil, transport: transport)

        let result = await search.search(.movie(imdbID: "tt1", title: nil))

        #expect(result.candidates.count == 2)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.hasPrefix("Broken: ") == true)
    }

    @Test func usageAndCapsPersist() async throws {
        let transport = MockTransport()
        try await stubIndexer(transport)
        let url = FileManager.default.temporaryDirectory.appending(path: "DoveKitTests-\(UUID().uuidString)/newznab.json")
        _ = await NewznabSearch(indexers: [indexer()], stateURL: url, transport: transport).search(.movie(imdbID: "tt1", title: nil))

        let reopened = NewznabSearch(indexers: [indexer()], stateURL: url, transport: transport)
        #expect(await reopened.usage(of: indexer()).hits == 2)
        _ = await reopened.search(.movie(imdbID: "tt2", title: nil))
        #expect(await transport.requests.filter { query($0)["t"] == "caps" }.count == 1)
    }

    @Test func sameReleaseFromTwoIndexersIsOneRowPlayedByNzbdav() {
        let a = StreamCandidate(id: "newznab:a:1", kind: .usenet, title: "Some.Movie.2023.1080p.WEB-DL-GRP", label: "Geek", size: 10, nzbURL: URL(string: "https://a.example/1")!)
        let b = StreamCandidate(id: "newznab:b:9", kind: .usenet, title: "Some Movie 2023 1080p WEB-DL-GRP", label: "Slug", size: 10, nzbURL: URL(string: "https://b.example/9")!)
        let routed = NewznabSearch.Results(candidates: [a, b], failures: []).routed(to: .nzbdav)
        let groups = StreamGroup.group(routed.candidates)

        #expect(groups.count == 1)
        #expect(groups[0].indexers == ["Geek", "Slug"])
        #expect(groups[0].availability.map(\.service) == ["nzbdav"])
        #expect(groups[0].cachedBackends() == [.nzbdav], "the Cached on filter and the ranking see nzbdav")
        #expect(SourceFilter.values(of: .cached, in: groups[0]) == ["nzbdav"])

        let torbox = NewznabSearch.Results(candidates: [a], failures: []).routed(to: .torBox).candidates[0]
        #expect(torbox.service == "torbox")
        #expect(torbox.cached == nil)
        #expect(NewznabSearch.Results(candidates: [a], failures: []).routed(to: .offcloud).candidates[0].service == "offcloud")
        #expect(NewznabSearch.Results(candidates: [a], failures: []).routed(to: nil).candidates[0].service == nil)
    }
}
