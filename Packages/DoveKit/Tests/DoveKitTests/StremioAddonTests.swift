import Foundation
import Testing
@testable import DoveKit

struct StremioAddonTests {
    private let base = "https://addon.example/stremio/00000000-0000-0000-0000-000000000000/eyJjb25maWciOnRydWV9"

    private func manifest(_ fixture: String) throws -> StremioManifest {
        try JSONDecoder().decode(StremioManifest.self, from: Fixture.data(fixture))
    }

    private func makeAddon(_ fixture: String) throws -> (StremioAddon, MockTransport) {
        let transport = MockTransport()
        let addon = StremioAddon(manifestURL: URL(string: "\(base)/manifest.json")!, manifest: try manifest(fixture), transport: transport)
        return (addon, transport)
    }

    // MARK: Manifest

    @Test func cinemetaSearchesItsPopularCatalog() throws {
        let cinemeta = try manifest("stremio_cinemeta_manifest")
        #expect(cinemeta.searchCatalog(for: .movie)?.id == "top")
        #expect(cinemeta.provides("meta"))
        #expect(!cinemeta.provides("stream"))
        #expect(cinemeta.accepts("meta", type: .series, id: "tt11280740"))
        #expect(!cinemeta.accepts("meta", type: .series, id: "tmdb:95396"))
    }

    @Test func aioMetadataPicksSearchCatalogsNotBrowseCatalogs() throws {
        let aiom = try manifest("stremio_aiometadata_manifest")
        #expect(aiom.searchCatalog(for: .movie)?.id == "search.movie")
        #expect(aiom.searchCatalog(for: .series)?.id == "search.series")
        #expect(aiom.canSearch)
    }

    @Test func aioStreamsObjectResourcesAreHonoured() throws {
        let aios = try manifest("stremio_aiostreams_manifest")
        #expect(aios.provides("stream"))
        #expect(aios.accepts("stream", type: .series, id: "tt11280740:1:1"))
        #expect(aios.accepts("stream", type: .movie, id: "tmdb:693134"))
        // Library catalogs need a genre, so they are not used for search.
        #expect(aios.searchCatalog(for: .movie)?.id.hasSuffix("search.movie") == true)
    }

    // MARK: Requests

    @Test func searchBuildsTheStremioExtraPath() async throws {
        let (addon, transport) = try makeAddon("stremio_aiometadata_manifest")
        await transport.stub("search=Diuna Część druga.json", body: try Fixture.data("stremio_search_movie"))

        let results = try await addon.search("Diuna Część druga", type: .movie)

        #expect(results.map(\.id) == ["tt15239678", "tt1160419", "tt0087182"])
        #expect(results[0].name == "Dune: Part Two")
        #expect(results[0].releaseInfo == "2024")
        #expect(results[0].poster != nil)
        let sent = try #require(await transport.requests.last?.url?.absoluteString)
        #expect(sent == "\(base)/catalog/movie/search.movie/search=Diuna%20Cz%C4%99%C5%9B%C4%87%20druga.json")
    }

    @Test func searchWithoutACatalogMakesNoRequest() async throws {
        let (addon, transport) = try makeAddon("stremio_aiostreams_manifest")
        let streamsOnly = StremioAddon(
            manifestURL: addon.manifestURL,
            manifest: try JSONDecoder().decode(StremioManifest.self, from: Data(#"{"id":"x","name":"X","resources":["stream"],"types":["movie"]}"#.utf8)),
            transport: transport
        )
        #expect(try await streamsOnly.search("Dune", type: .movie).isEmpty)
        #expect(await transport.requests.isEmpty)
    }

    @Test func metaGroupsEpisodesBySeasonWithSpecialsLast() async throws {
        let (addon, transport) = try makeAddon("stremio_aiometadata_manifest")
        await transport.stub("meta/series/tt11280740.json", body: try Fixture.data("stremio_meta_series"))

        let detail = try await addon.meta(type: .series, id: "tt11280740")

        #expect(detail.summary.name == "Severance")
        #expect(detail.seasons == [1, 2, 0])
        let season1 = detail.episodes(inSeason: 1)
        #expect(season1.map(\.id) == ["tt11280740:1:1", "tt11280740:1:2", "tt11280740:1:3"])
        #expect(season1[0].title == "Good News About Hell")
        #expect(season1[0].released != nil)
    }

    @Test func episodeIDKeepsItsColonsInTheStreamPath() async throws {
        let (addon, transport) = try makeAddon("stremio_aiostreams_manifest")
        await transport.stub("stream/series/tt11280740:1:1.json", body: try Fixture.data("stremio_streams_episode"))

        let streams = try await addon.streams(type: .series, id: "tt11280740:1:1")

        #expect(streams.count == 3)
        let sent = try #require(await transport.requests.last?.url?.absoluteString)
        #expect(sent == "\(base)/stream/series/tt11280740:1:1.json")
    }

    @Test func streamsUseTheFilenameAndCleanThePaddedLabel() async throws {
        let (addon, transport) = try makeAddon("stremio_aiostreams_manifest")
        await transport.stub("stream/series/tt11280740:1:1.json", body: try Fixture.data("stremio_streams_episode"))

        let stream = try #require(try await addon.streams(type: .series, id: "tt11280740:1:1").dropFirst().first)

        #expect(stream.title == "Severance S01E01 Good News About Hell BluRay 1080p DTS-HD MA 5 1 AVC REMUX-FraMeSToR.mkv")
        #expect(stream.kind == .debrid)
        #expect(stream.url != nil)
        #expect(stream.cached == true)
        #expect(!stream.label.contains("\u{200D}"))
        #expect(!stream.label.contains("\u{00A0}"))
        #expect(stream.librarySource == nil)
    }

    @Test func textCleanupCollapsesPadding() {
        #expect(StremioText.clean("\u{00A0}\u{00A0}4K\u{200D}\u{00A0}  ⚡  Remux\n  line two ") == "4K ⚡ Remux\nline two")
    }

    @Test func httpErrorsAreMapped() async throws {
        let (addon, transport) = try makeAddon("stremio_cinemeta_manifest")
        await transport.stub("meta/movie/tt0.json", status: 404, json: "{}")
        await #expect(throws: BackendError.notFound) {
            try await addon.meta(type: .movie, id: "tt0")
        }
    }

    @Test func manifestURLMustEndWithManifestJSON() async {
        await #expect(throws: BackendError.self) {
            try await StremioAddon.load(manifestURL: URL(string: "https://addon.example/configure")!, transport: MockTransport())
        }
    }
}

struct AIOStreamsSearchTests {
    private func makeClient() -> (AIOStreamsSearch, MockTransport) {
        let transport = MockTransport()
        let client = AIOStreamsSearch(
            origin: URL(string: "https://aio.example")!,
            uuid: "00000000-0000-0000-0000-000000000000",
            password: "secret",
            transport: transport
        )
        return (client, transport)
    }

    @Test func recognisesAnAIOStreamsManifestURL() throws {
        let url = URL(string: "https://aio.example/stremio/12345678-90ab-4cde-8f01-23456789abcd/eyJhIjoxfQ/manifest.json")!
        let instance = try #require(AIOStreamsSearch.instance(from: url))
        #expect(instance.origin.absoluteString == "https://aio.example")
        #expect(instance.uuid == "12345678-90ab-4cde-8f01-23456789abcd")
        #expect(instance.variant == nil)
        #expect(AIOStreamsSearch.instance(from: URL(string: "https://v3-cinemeta.strem.io/manifest.json")!) == nil)
        // AIOMetadata uses the same prefix, without the config segment.
        #expect(AIOStreamsSearch.instance(from: URL(string: "https://aiometadata.example/stremio/12345678-90ab-4cde-8f01-23456789abcd/manifest.json")!) == nil)
    }

    @Test func variantIsReadFromPathOrQuery() throws {
        let path = URL(string: "https://aio.example/stremio/12345678-90ab-4cde-8f01-23456789abcd/eyJhIjoxfQ/v/dove/manifest.json")!
        #expect(AIOStreamsSearch.instance(from: path)?.variant == "dove")
        let query = URL(string: "https://aio.example/stremio/12345678-90ab-4cde-8f01-23456789abcd/eyJhIjoxfQ/manifest.json?v=full")!
        #expect(AIOStreamsSearch.instance(from: query)?.variant == "full")
    }

    @Test func variantIsSentToTheSearchAPI() async throws {
        let transport = MockTransport()
        await transport.stub("api/v1/search", body: try Fixture.data("aiostreams_search_episode"))
        let client = AIOStreamsSearch(origin: URL(string: "https://aio.example")!, uuid: "u", password: "p", variant: "dove", transport: transport)

        _ = try await client.search(type: .movie, id: "tt1160419")

        let sent = try #require(await transport.requests.last?.url)
        let query = URLComponents(url: sent, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "v", value: "dove")))
    }

    @Test func searchSendsBasicAuthAndQuery() async throws {
        let (client, transport) = makeClient()
        await transport.stub("api/v1/search", body: try Fixture.data("aiostreams_search_episode"))

        _ = try await client.search(type: .series, id: "tt11280740:1:1")

        let sent = try #require(await transport.requests.last)
        let expected = "Basic " + Data("00000000-0000-0000-0000-000000000000:secret".utf8).base64EncodedString()
        #expect(sent.value(forHTTPHeaderField: "Authorization") == expected)
        let query = URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "id", value: "tt11280740:1:1")))
        #expect(query.contains(URLQueryItem(name: "type", value: "series")))
    }

    @Test func resultsCarryStructuredFields() async throws {
        let (client, transport) = makeClient()
        await transport.stub("api/v1/search", body: try Fixture.data("aiostreams_search_episode"))

        let results = try await client.search(type: .series, id: "tt11280740:1:1")
        let candidates = results.candidates

        #expect(candidates.map(\.kind) == [.usenet, .debrid, .debrid, .debrid])
        #expect(candidates.map(\.service) == ["nzbdav", "offcloud", "realdebrid", "torbox"])
        // A season pack: the 97 GB folder holds the 12 GB episode.
        #expect(candidates[2].folderName == "Severance S01 1080p BluRay REMUX AVC DTS-HD MA 5 1-TRiToN")
        #expect(candidates[1].isPack)
        #expect(candidates[2].fileIndex == 0)
        // `fileIdx: -1` means unknown.
        #expect(candidates[3].fileIndex == nil)
        #expect(candidates[1].traits?.resolution == "1080p")
        #expect(candidates[1].librarySource == .magnet("magnet:?xt=urn:btih:3133f1ac4b86226ca105e69b1c1374ef552380b5"))
        #expect(candidates[0].librarySource == nil)
        #expect(results.sourceErrors.contains { $0.contains("NOAUTH") })
    }

    @Test func badCredentialsAreUnauthorized() async {
        let (client, transport) = makeClient()
        await transport.stub("api/v1/search", status: 401, json: #"{"success":false,"detail":null,"error":{"code":"BAD_REQUEST","message":"Invalid credentials"},"data":null}"#)
        await #expect(throws: BackendError.unauthorized) {
            try await client.search(type: .movie, id: "tt1160419")
        }
    }
}

struct TorrentioStreamTests {
    @Test func p2pStreamsCarryHashSizeAndTraits() async throws {
        let transport = MockTransport()
        await transport.stub("stream/movie/tt1160419.json", body: try Fixture.data("torrentio_streams_movie"))
        let manifest = try JSONDecoder().decode(
            StremioManifest.self,
            from: Data(#"{"id":"com.stremio.torrentio.addon","name":"Torrentio","resources":["stream"],"types":["movie","series"],"idPrefixes":["tt"]}"#.utf8)
        )
        let addon = StremioAddon(manifestURL: URL(string: "https://torrentio.example/manifest.json")!, manifest: manifest, transport: transport)

        let streams = try await addon.streams(type: .movie, id: "tt1160419")

        let first = try #require(streams.first)
        #expect(first.kind == .p2p)
        #expect(first.infoHash == "799dbc6af33a8f32bf1406dc2ec68bbb6864affb")
        #expect(first.fileIndex == 0)
        #expect(first.size == 20_320_000_000)
        #expect(first.title == "Dune.2021.2160p.HMAX.WEB-DL.DDP5.1.Atmos.HDR.HEVC-EVO.mkv")
        #expect(first.librarySource == .magnet("magnet:?xt=urn:btih:799dbc6af33a8f32bf1406dc2ec68bbb6864affb"))
        let group = StreamGroup.group([first])[0]
        #expect(group.traits.resolution == "2160p")
        #expect(group.traits.quality == "WEB-DL")
    }

    @Test func sizeIsReadFromTitleText() {
        #expect(StremioText.size(in: "👤 239 💾 20.32 GB ⚙️ TPB") == 20_320_000_000)
        #expect(StremioText.size(in: "💾 700 MB") == 700_000_000)
        #expect(StremioText.size(in: "💾 1,5 TB") == 1_500_000_000_000)
        #expect(StremioText.size(in: "no size here") == nil)
    }

    @Test func defaultSortIsLargestFirst() {
        #expect(SourceFilter().sort == .sizeDescending)
    }
}
