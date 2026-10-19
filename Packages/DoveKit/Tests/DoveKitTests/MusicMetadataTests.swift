import Foundation
import Testing
@testable import DoveKit

struct MusicMetadataTests {
    private func metadata(_ transport: MockTransport) -> MusicMetadata {
        MusicMetadata(transport: transport, gate: MusicBrainzGate(interval: .zero))
    }

    @Test func searchesAlbumsAndRanksTheOneTheWordsName() async throws {
        let transport = MockTransport()
        await transport.stub("/ws/2/release-group", body: try Fixture.data("musicbrainz_release_groups"))
        let albums = try await metadata(transport).search("daft punk random access memories")

        #expect(albums.first?.title == "Random Access Memories" && albums.first?.artists == ["Daft Punk"], "title and artist named beat the title alone")
        #expect(albums.first?.year == 2013 && albums.first?.type == "Album")
        #expect(albums.first?.cover?.absoluteString.hasPrefix("https://coverartarchive.org/release-group/") == true)
        #expect(albums.first?.id.hasPrefix("mb:") == true && albums.first?.releaseID != nil)
        let others = albums.filter { $0.title == "Random Access Memories" && $0.artists != ["Daft Punk"] }
        #expect(others.map(\.artists) == [["Franz Kirmann"], ["Jarel Gomes"]], "official before bootleg-only")

        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Dove") == true)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "fmt", value: "json")))
        #expect(query.contains(URLQueryItem(name: "query", value: "releasegroup:(daft punk random access memories) OR artist:(daft punk random access memories)")))
        #expect(MusicMetadata.luceneQuery("AC/DC: Back") == #"releasegroup:(AC\/DC\: Back) OR artist:(AC\/DC\: Back)"#)

        let byWords = try await metadata(transport).search("random access memories")
        #expect(byWords.prefix(2).map(\.artists) == [["Daft Punk"], ["Franz Kirmann"]], "title alone: the most released first")
    }

    @Test func anArtistsNameBringsItsAlbums() async throws {
        let transport = MockTransport()
        await transport.stub("/ws/2/release-group", body: try Fixture.data("musicbrainz_release_groups"))
        await transport.stub("/ws/2/release-group", queryContains: "arid", json: #"""
        {"release-groups":[{"id":"hw","title":"Homework","primary-type":"Album","first-release-date":"1997-01-20","count":30,
          "artist-credit":[{"name":"Daft Punk","artist":{"id":"056e4f3e-d505-4dad-8ec1-d04f521cbb56","name":"Daft Punk"}}],
          "releases":[{"id":"r1","title":"Homework","status":"Official"}]}]}
        """#)
        let albums = try await metadata(transport).search("Daft Punk")

        let asked = await transport.requests.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value }
        #expect(asked.last == "arid:056e4f3e-d505-4dad-8ec1-d04f521cbb56 AND primarytype:album AND status:official")
        #expect(albums.prefix(3).map(\.title) == ["Homework", "Discovery", "Random Access Memories"], "the artist's studio albums, most released first")
        #expect(albums.filter { $0.artists == ["Daft Punk"] }.count == 3, "no duplicates")

        let none = MockTransport()
        await none.stub("/ws/2/release-group", body: try Fixture.data("musicbrainz_release_groups"))
        _ = try await metadata(none).search("random access memories")
        #expect(await none.requests.count == 1, "not an artist's name: one call")
    }

    private struct FakeCatalog: AlbumCatalog {
        var albums: [AlbumSummary] = []
        var fails = false
        let name = "Fake"

        func owns(_ albumID: String) -> Bool { albumID.hasPrefix("am:") }

        func albums(matching query: String) async throws -> [AlbumSummary] {
            if fails { throw BackendError.api(message: "catalog down") }
            return albums
        }

        func tracks(ofAlbum id: String) async throws -> [AlbumTrack] {
            [AlbumTrack(id: "\(id)/1", position: 1, title: "From the catalog")]
        }
    }

    @Test func catalogAlbumsMergeWithMusicBrainz() async throws {
        let transport = MockTransport()
        await transport.stub("/ws/2/release-group", body: try Fixture.data("musicbrainz_release_groups"))
        let cover = URL(string: "https://is1.mzstatic.com/ram.jpg")!
        let catalog = FakeCatalog(albums: [
            AlbumSummary(id: "am:1", title: "Random Access Memories", artists: ["Daft Punk"], year: 2013, cover: cover, type: "Album"),
            AlbumSummary(id: "am:2", title: "Spokojnie", artists: ["Kult"], year: 1988, type: "Album"),
        ])
        let metadata = MusicMetadata(catalogs: [catalog], transport: transport, gate: MusicBrainzGate(interval: .zero))
        let albums = try await metadata.search("daft punk random access memories")

        let ram = try #require(albums.first)
        #expect(ram.id.hasPrefix("mb:") && ram.catalogID == "am:1" && ram.cover == cover, "one row: MusicBrainz's, the catalog's ID and cover")
        #expect(albums.filter { $0.title == "Random Access Memories" && $0.artists == ["Daft Punk"] }.count == 1)
        #expect(albums.contains { $0.id == "am:2" }, "albums only the catalog has are added")
        #expect(try await metadata.tracks(of: albums.first { $0.id == "am:2" }!).map(\.title) == ["From the catalog"])

        let musicBrainzDown = MockTransport()
        await musicBrainzDown.stub("/ws/2/release-group", status: 500, json: "{}")
        let fallback = MusicMetadata(catalogs: [catalog], transport: musicBrainzDown, gate: MusicBrainzGate(interval: .zero))
        #expect(try await fallback.search("spokojnie").map(\.id) == ["am:2", "am:1"], "the catalog alone answers")

        let catalogDown = MusicMetadata(catalogs: [FakeCatalog(fails: true)], transport: transport, gate: MusicBrainzGate(interval: .zero))
        #expect(try await catalogDown.search("discovery").count == 4, "MusicBrainz alone answers")
        let bothDown = MusicMetadata(catalogs: [FakeCatalog(fails: true)], transport: musicBrainzDown, gate: MusicBrainzGate(interval: .zero))
        await #expect(throws: BackendError.self) { try await bothDown.search("discovery") }
    }

    @Test func tracksInDiscOrder() async throws {
        let transport = MockTransport()
        await transport.stub("/ws/2/release/8d28a4da-8077-4cae-a0a1-2d16c4923775", body: try Fixture.data("musicbrainz_release"))
        let album = AlbumSummary(id: "mb:x", title: "Discovery", releaseID: "8d28a4da-8077-4cae-a0a1-2d16c4923775")
        let tracks = try await metadata(transport).tracks(of: album)

        #expect(tracks.map(\.title) == ["One More Time", "Aerodynamic", "Digital Love", "Bonus Track"])
        #expect(tracks.map(\.disc) == [1, 1, 1, 2])
        #expect(tracks[0].duration.map { Int($0) } == 320 && tracks[3].duration == nil)
        #expect(try await metadata(transport).tracks(of: AlbumSummary(id: "mb:y", title: "No release")).isEmpty)
    }

    @Test func busyAnswersAreAskedAgainThenSaid() async throws {
        let transport = MockTransport()
        await transport.stub("/ws/2/release-group", status: 503, json: #"{"error":"busy"}"#)
        await transport.stub("/ws/2/release-group", body: try Fixture.data("musicbrainz_release_groups"))
        #expect(try await metadata(transport).search("discovery").count == 4)
        #expect(await transport.requests.count == 2)

        let busy = MockTransport()
        await busy.stub("/ws/2/release-group", status: 503, json: #"{"error":"busy"}"#)
        await #expect(throws: BackendError.api(message: "MusicBrainz is busy. Try again in a moment.")) {
            try await metadata(busy).search("discovery")
        }
        #expect(await busy.requests.count == 4)
    }

    @Test func releaseNamesMatchTheirAlbum() {
        let album = AlbumSummary(id: "mb:1", title: "Discovery (Deluxe Edition)", artists: ["Daft Punk"])
        #expect(album.searchTitle == "Discovery")
        #expect(AlbumMatcher.matches("Daft_Punk-Discovery-CD-FLAC-2001-PERFECT", album))
        #expect(AlbumMatcher.matches("Daft Punk - Discovery (2001) [FLAC 24-96]", album))
        #expect(!AlbumMatcher.matches("Discovery Channel - Soundtrack (2001) [MP3]", album), "the artist is needed")
        #expect(!AlbumMatcher.matches("Daft Punk - Homework (1997) [FLAC]", album))

        let compilation = AlbumSummary(id: "mb:2", title: "Ministry of Sound Annual", artists: ["Various Artists"])
        #expect(AlbumMatcher.matches("VA - Ministry Of Sound Annual 2003 [MP3 320]", compilation))

        let groups = StreamGroup.group(["Daft Punk - Discovery [FLAC]", "Daft Punk - Alive 2007 [FLAC]"].map {
            StreamCandidate(id: $0, kind: .usenet, title: $0, category: 3000)
        })
        let split = StreamGroup.split(groups, for: album)
        #expect(split.thisAlbum.map(\.title) == ["Daft Punk - Discovery [FLAC]"] && split.other.count == 1)
    }
}
