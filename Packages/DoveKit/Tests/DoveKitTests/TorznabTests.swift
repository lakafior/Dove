import Foundation
import Testing
@testable import DoveKit

struct TorznabTests {
    private let jackett = NewznabIndexer(
        id: "jackett", kind: .torznab, name: "Jackett",
        url: URL(string: "http://192.168.1.10:9117/api/v2.0/indexers/all/results/torznab")!, apiKey: "KEY"
    )
    private let caps = NewznabCaps(movieParams: ["q", "imdbid"], tvParams: ["q"], maxLimit: 100)

    private func search(_ query: NewznabQuery) async throws -> [StreamCandidate] {
        let transport = MockTransport()
        await transport.stub("/torznab/api", body: try Fixture.data("torznab_search", extension: "xml"), contentType: "application/rss+xml")
        return try #require(try await NewznabClient(indexer: jackett, transport: transport).search(query, caps: caps))
    }

    @Test func resultsBecomeTorrentsWithHashesMagnetsOrTorrentLinks() async throws {
        let found = try await search(.text("some", category: .all))
        #expect(found.map(\.title) == ["Some.Movie.2023.1080p.BluRay.x264-GRP", "Some.Album.2023.FLAC", "Some.Program.v2.0.x64"])
        #expect(found.allSatisfy { $0.kind == .p2p && $0.label == "Jackett" && $0.nzbURL == nil })

        let movie = found[0]
        #expect(movie.infoHash == String(repeating: "a", count: 40))
        #expect(movie.seeders == 120)
        #expect(movie.category == 2000, "Jackett's own 100000+ categories are ignored")
        #expect(movie.size == 9_000_000_000)
        // The .torrent wins over the magnet: only the file says whether it is private (and carries the passkey).
        #expect(movie.torrentURL?.host() == "192.168.1.10")
        #expect(movie.librarySource == .torrentURL(movie.torrentURL!))

        #expect(found[1].infoHash == String(repeating: "b", count: 40), "hash read from a magnet link")
        #expect(found[1].category == 3040)
        #expect(found[1].torrentURL == nil)
        #expect(found[1].librarySource == .magnet(infoHash: String(repeating: "b", count: 40), name: found[1].title))

        let program = found[2]
        #expect(movie.provider == "Jackett" && movie.tracker == "Public Tracker" && movie.isPrivate == false)
        #expect(movie.origin == ["Jackett", "Public Tracker"])
        #expect(movie.published == Date(timeIntervalSince1970: 1791885600))
        #expect(found[1].tracker == nil && found[1].isPrivate == nil, "no jackettindexer or type")
        #expect(program.tracker == "Private Tracker")
        #expect(program.isPrivate == true, "semi-private trackers want seeding too")
        #expect(program.infoHash == nil)
        #expect(program.torrentURL?.host() == "192.168.1.10")
        #expect(program.librarySource == .torrentURL(program.torrentURL!))
    }

    @Test func movieSearchesKeepMoviesOnly() async throws {
        let found = try await search(.movie(imdbID: "tt1", title: "Some Movie"))
        #expect(found.map(\.title) == ["Some.Movie.2023.1080p.BluRay.x264-GRP"])
    }

    @Test func theSameTorrentFromTwoTrackersIsOneRow() {
        let hash = String(repeating: "e", count: 40)
        let groups = StreamGroup.group([
            StreamCandidate(id: "newznab:jackett:1", kind: .p2p, title: "Some.Program", label: "Jackett", infoHash: hash, category: 4000, seeders: 3),
            StreamCandidate(id: "newznab:prowlarr:9", kind: .p2p, title: "Some.Program", label: "Prowlarr", infoHash: hash.uppercased(), seeders: 40),
        ])
        #expect(groups.count == 1)
        #expect(groups[0].seeders == 40)
        #expect(groups[0].category == 4000)
        #expect(groups[0].indexers == ["Jackett", "Prowlarr"])
    }

    @Test func routingLeavesTorrentsToTheDebrids() {
        let torrent = StreamCandidate(id: "t", kind: .p2p, title: "T", infoHash: String(repeating: "c", count: 40))
        let nzb = StreamCandidate(id: "n", kind: .usenet, title: "N", nzbURL: URL(string: "https://i.example/get/1")!)
        let routed = NewznabSearch.Results(candidates: [torrent, nzb], failures: []).routed(to: .nzbdav)
        #expect(routed.candidates[0].service == nil && routed.candidates[0].cached == nil)
        #expect(routed.candidates[1].service == "nzbdav")
    }

    @Test func savedIndexersWithoutAKindAreNewznab() throws {
        let json = #"[{"id":"a","name":"Geek","url":"https://api.nzbgeek.info","apiPath":"/api","apiKey":"K","enabled":true}]"#
        let decoded = try JSONDecoder().decode([NewznabIndexer].self, from: Data(json.utf8))
        #expect(decoded.first?.kind == .newznab)
        let roundTrip = try JSONDecoder().decode(NewznabIndexer.self, from: JSONEncoder().encode(jackett))
        #expect(roundTrip == jackett)
    }

    @Test func jackettPathsKeepTheirTorznabEndpoint() {
        let pasted = NewznabIndexer.normalized(url: "http://192.168.1.10:9117/api/v2.0/indexers/all/results/torznab/api?apikey=x")
        #expect(pasted?.url.absoluteString == "http://192.168.1.10:9117/api/v2.0/indexers/all/results/torznab")
        #expect(pasted?.apiPath == "/api")
        #expect(NewznabIndexer.normalized(url: "http://prowlarr.lan:9696/1/api")?.url.path() == "/1")
    }

    // MARK: - Torrent links

    private let link = URL(string: "http://192.168.1.10:9117/dl/private/?jackett_apikey=KEY&path=xyz")!

    @Test func torrentLinksAreFetchedOnThePhone() async throws {
        let transport = MockTransport()
        await transport.stub("/dl/private", status: 200, headers: ["Content-Disposition": #"attachment; filename="Some.Program.torrent""#], body: Data("d8:announce3:urle".utf8))
        let source = try await IndexerTorrent.prepare(.torrentURL(link), transport: transport)
        #expect(source == .torrentFile(data: Data("d8:announce3:urle".utf8), filename: "Some.Program.torrent"))
    }

    @Test func redirectsToMagnetsBecomeMagnets() async throws {
        let transport = MockTransport()
        let magnet = "magnet:?xt=urn:btih:" + String(repeating: "d", count: 40)
        await transport.stub("/dl/private", status: 302, headers: ["Location": magnet])
        #expect(try await IndexerTorrent.prepare(.torrentURL(link), transport: transport) == .magnet(magnet))
    }

    @Test func errorPagesAreNotTorrents() async throws {
        let transport = MockTransport()
        await transport.stub("/dl/private", status: 200, headers: [:], body: Data("<html>Login</html>".utf8))
        await #expect(throws: BackendError.api(message: "The indexer did not return a torrent file.")) {
            try await IndexerTorrent.prepare(.torrentURL(link), transport: transport)
        }
        let magnet = Source.magnet("magnet:?xt=urn:btih:x")
        #expect(try await IndexerTorrent.prepare(magnet, transport: transport) == magnet, "other sources pass through")
    }
}
