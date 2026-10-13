import Foundation
import Testing
@testable import DoveKit

struct TMDBMetadataTests {
    private let v3Key = "0123456789abcdef0123456789abcdef"
    private let v4Token = "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJ4In0.c2ln"

    @Test func multiSearchKeepsMoviesAndSeriesAndBuildsImageURLs() async throws {
        let transport = MockTransport()
        await transport.stub("3/search/multi", body: try Fixture.data("tmdb_search_multi"))
        let tmdb = TMDBMetadata(key: v3Key, transport: transport)

        let results = try await tmdb.search("Dune")

        #expect(results.map(\.id) == ["tmdb:693134", "tmdb:1885", "tmdb:438631"])
        #expect(results.map(\.type) == [.movie, .series, .movie])
        #expect(results[0].releaseInfo == "2024")
        #expect(results[0].poster?.absoluteString == "https://image.tmdb.org/t/p/w342/p1.jpg")
        #expect(results[0].background?.absoluteString == "https://image.tmdb.org/t/p/w1280/bg1.jpg")
        #expect(results[1].description == nil)
        #expect(results[2].poster == nil)
        #expect(results[2].releaseInfo == nil)
    }

    @Test func v3KeyTravelsInTheQueryAndV4TokenAsBearer() async throws {
        let transport = MockTransport()
        await transport.stub("3/search/tv", json: #"{"results":[]}"#)

        _ = try await TMDBMetadata(key: v3Key, transport: transport).search("Dune", type: .series)
        _ = try await TMDBMetadata(key: v4Token, transport: transport).search("Dune", type: .series)

        let requests = await transport.requests
        let v3 = try #require(URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false))
        #expect(v3.queryItems?.first { $0.name == "api_key" }?.value == v3Key)
        #expect(v3.queryItems?.first { $0.name == "language" }?.value == "en-US")
        #expect(v3.queryItems?.first { $0.name == "query" }?.value == "Dune")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer \(v4Token)")
        #expect(requests[1].url?.query?.contains("api_key") == false)
    }

    @Test func seriesDetailUsesTheIMDbIDForEpisodesAndSkipsEmptySeasons() async throws {
        let transport = MockTransport()
        await transport.stub("3/tv/95396", queryContains: "external_ids", body: try Fixture.data("tmdb_tv_detail"))
        await transport.stub("3/tv/95396", queryContains: "season/1", body: try Fixture.data("tmdb_tv_seasons"))
        let tmdb = TMDBMetadata(key: v3Key, transport: transport)

        let detail = try await tmdb.detail(of: MediaSummary(id: "tmdb:95396", type: .series, name: "Severance"))

        #expect(detail.summary.id == "tt11280740")
        #expect(detail.summary.poster?.absoluteString == "https://image.tmdb.org/t/p/w342/sev.jpg")
        #expect(detail.genres == ["Drama", "Mystery"])
        #expect(detail.runtime == "55 min")
        #expect(detail.seasons == [1, 2])
        #expect(detail.episodes.map(\.id) == ["tt11280740:1:1", "tt11280740:1:2", "tt11280740:2:1"])
        let pilot = try #require(detail.episodes.first)
        #expect(pilot.title == "Good News About Hell")
        #expect(pilot.thumbnail?.absoluteString == "https://image.tmdb.org/t/p/w300/e1.jpg")
        #expect(pilot.released == TMDBMetadata.parseDay("2022-02-18"))
        #expect(detail.episodes[1].overview == nil)
        #expect(detail.episodes[2].released == nil)
        // Season 0 has no episodes, so only seasons 1 and 2 are appended.
        let seasonsQuery = await transport.requests.last?.url?.query ?? ""
        #expect(seasonsQuery.contains("append_to_response=season/1,season/2"))
    }

    @Test func imdbIDsAreFoundFirst() async throws {
        let transport = MockTransport()
        await transport.stub("3/find/tt11280740", body: try Fixture.data("tmdb_find"))
        await transport.stub("3/tv/95396", queryContains: "external_ids", body: try Fixture.data("tmdb_tv_detail"))
        await transport.stub("3/tv/95396", queryContains: "season/1", body: try Fixture.data("tmdb_tv_seasons"))
        let tmdb = TMDBMetadata(key: v3Key, transport: transport)

        let detail = try await tmdb.detail(of: MediaSummary(id: "tt11280740", type: .series, name: "Severance"))

        #expect(detail.episodes.count == 3)
        let find = await transport.requests.first?.url?.query ?? ""
        #expect(find.contains("external_source=imdb_id"))
    }

    @Test func movieDetailHasNoEpisodes() async throws {
        let transport = MockTransport()
        await transport.stub("3/movie/693134", body: try Fixture.data("tmdb_movie_detail"))

        let detail = try await TMDBMetadata(key: v3Key, transport: transport)
            .detail(of: MediaSummary(id: "tmdb:693134", type: .movie, name: "Dune: Part Two"))

        #expect(detail.summary.id == "tt15239678")
        #expect(detail.runtime == "167 min")
        #expect(detail.episodes.isEmpty)
        #expect(await transport.requests.count == 1)
    }

    @Test func titleWithoutIMDbIDKeepsTheTMDBID() async throws {
        let transport = MockTransport()
        await transport.stub("3/movie/1", json: #"{"id":1,"title":"Obscure","imdb_id":null,"external_ids":{"imdb_id":null}}"#)

        let detail = try await TMDBMetadata(key: v3Key, transport: transport)
            .detail(of: MediaSummary(id: "tmdb:1", type: .movie, name: "Obscure"))

        #expect(detail.summary.id == "tmdb:1")
    }

    @Test func badKeyGivesAReadableError() async throws {
        let transport = MockTransport()
        await transport.stub("3/authentication", status: 401, json: #"{"status_code":7,"status_message":"Invalid API key","success":false}"#)

        await #expect(throws: BackendError.self) {
            try await TMDBMetadata(key: "wrong", transport: transport).validate()
        }
    }

    @Test func seriesEpisodesComeFromTheMetadataAddonAndTheRestFromTMDB() async throws {
        let addonTransport = MockTransport()
        await addonTransport.stub("meta/series/tt11280740.json", body: try Fixture.data("stremio_meta_series"))
        let manifest = try JSONDecoder().decode(StremioManifest.self, from: Fixture.data("stremio_aiometadata_manifest"))
        let addon = StremioAddon(manifestURL: URL(string: "https://meta.example/manifest.json")!, manifest: manifest, transport: addonTransport)
        let tmdbTransport = MockTransport()
        await tmdbTransport.stub("3/tv/95396", queryContains: "external_ids", body: try Fixture.data("tmdb_tv_detail"))
        await tmdbTransport.stub("3/tv/95396", queryContains: "season/1", body: try Fixture.data("tmdb_tv_seasons"))
        let set = AddonSet(addons: [addon], tmdb: TMDBMetadata(key: v3Key, transport: tmdbTransport))

        let detail = try await set.detail(of: MediaSummary(id: "tmdb:95396", type: .series, name: "Severance"))

        #expect(detail.summary.poster?.absoluteString == "https://image.tmdb.org/t/p/w342/sev.jpg")
        #expect(detail.seasons == [1, 2, 0])
        #expect(detail.episodes(inSeason: 1).count == 3)
        // TMDB was asked for the title only, never for its seasons.
        #expect(await tmdbTransport.requests.count == 1)

        // No addon answers: TMDB's own episodes.
        let failing = MockTransport()
        await failing.stub("meta/series/tt11280740.json", status: 500, json: "{}")
        let broken = StremioAddon(manifestURL: URL(string: "https://meta.example/manifest.json")!, manifest: manifest, transport: failing)
        let fallback = try await AddonSet(addons: [broken], tmdb: TMDBMetadata(key: v3Key, transport: tmdbTransport))
            .detail(of: MediaSummary(id: "tmdb:95396", type: .series, name: "Severance"))
        #expect(fallback.episodes.map(\.id) == ["tt11280740:1:1", "tt11280740:1:2", "tt11280740:2:1"])
    }

    @Test func addonSetPrefersTMDBAndFallsBackToTheAddon() async throws {
        let addonTransport = MockTransport()
        await addonTransport.stub("search.movie/search=Dune.json", body: try Fixture.data("stremio_search_movie"))
        await addonTransport.stub("search.series/search=Dune.json", json: #"{"metas":[]}"#)
        let manifest = try JSONDecoder().decode(StremioManifest.self, from: Fixture.data("stremio_aiometadata_manifest"))
        let addon = StremioAddon(manifestURL: URL(string: "https://meta.example/manifest.json")!, manifest: manifest, transport: addonTransport)

        let tmdbTransport = MockTransport()
        await tmdbTransport.stub("3/search/multi", body: try Fixture.data("tmdb_search_multi"))
        let withTMDB = AddonSet(addons: [addon], tmdb: TMDBMetadata(key: v3Key, transport: tmdbTransport))
        #expect(try await withTMDB.search("Dune").first?.id == "tmdb:693134")
        #expect(await addonTransport.requests.isEmpty)

        let failing = MockTransport()
        await failing.stub("3/search/multi", status: 503, json: "{}")
        let fallback = AddonSet(addons: [addon], tmdb: TMDBMetadata(key: v3Key, transport: failing))
        #expect(try await fallback.search("Dune").first?.id.hasPrefix("tt") == true)

        // TMDB alone can search; its errors reach the caller when no addon can take over.
        let alone = AddonSet(addons: [], tmdb: TMDBMetadata(key: v3Key, transport: failing))
        #expect(alone.canSearch)
        await #expect(throws: BackendError.self) { try await alone.search("Dune") }
    }
}
