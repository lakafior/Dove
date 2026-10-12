import Foundation
import Testing
@testable import DoveKit

struct AddonSetTests {
    private let aioURL = URL(string: "https://aio.example/stremio/00000000-0000-0000-0000-000000000000/eyJ4IjoxfQ/manifest.json")!

    private func addon(_ fixture: String, url: URL, transport: MockTransport) throws -> StremioAddon {
        let manifest = try JSONDecoder().decode(StremioManifest.self, from: Fixture.data(fixture))
        return StremioAddon(manifestURL: url, manifest: manifest, transport: transport)
    }

    @Test func firstSearchCapableAddonSearchesBothTypes() async throws {
        let transport = MockTransport()
        await transport.stub("search.movie/search=Dune.json", body: try Fixture.data("stremio_search_movie"))
        await transport.stub("search.series/search=Dune.json", json: #"{"metas":[{"id":"tt0142032","type":"series","name":"Dune"}]}"#)
        let set = AddonSet(addons: [
            try addon("stremio_aiometadata_manifest", url: URL(string: "https://meta.example/manifest.json")!, transport: transport)
        ])

        let results = try await set.search("Dune")

        #expect(results.map(\.id) == ["tt15239678", "tt0142032", "tt1160419", "tt0087182"])
    }

    @Test func searchAPIReplacesTheSameInstancesStreamRoute() async throws {
        let addonTransport = MockTransport()
        let apiTransport = MockTransport()
        await apiTransport.stub("api/v1/search", body: try Fixture.data("aiostreams_search_episode"))
        let set = AddonSet(
            addons: [try addon("stremio_aiostreams_manifest", url: aioURL, transport: addonTransport)],
            aioStreams: AIOStreamsSearch(
                origin: URL(string: "https://aio.example")!,
                uuid: "00000000-0000-0000-0000-000000000000",
                password: "p",
                transport: apiTransport
            )
        )

        let streams = await set.streams(type: .series, id: "tt11280740:1:1")

        #expect(streams.candidates.count == 4)
        #expect(await addonTransport.requests.isEmpty)
        #expect(streams.failures.contains { $0.contains("NOAUTH") })
    }

    @Test func failingAddonIsReportedAndOthersStillAnswer() async throws {
        let good = MockTransport()
        await good.stub("stream/series/tt11280740:1:1.json", body: try Fixture.data("stremio_streams_episode"))
        let bad = MockTransport()
        await bad.stub("stream/series/tt11280740:1:1.json", status: 500, json: "{}")
        let set = AddonSet(addons: [
            try addon("stremio_aiostreams_manifest", url: URL(string: "https://bad.example/manifest.json")!, transport: bad),
            try addon("stremio_aiostreams_manifest", url: aioURL, transport: good)
        ])

        let streams = await set.streams(type: .series, id: "tt11280740:1:1")

        #expect(streams.candidates.count == 3)
        #expect(streams.failures.count == 1)
    }

    @Test func detailFallsBackToTheSummary() async throws {
        let transport = MockTransport()
        let set = AddonSet(addons: [try addon("stremio_cinemeta_manifest", url: URL(string: "https://c.example/manifest.json")!, transport: transport)])
        let item = MediaSummary(id: "kitsu:1", type: .series, name: "Cowboy Bebop")

        let detail = try await set.detail(of: item)

        #expect(detail.summary == item)
        #expect(await transport.requests.isEmpty)
    }
}
