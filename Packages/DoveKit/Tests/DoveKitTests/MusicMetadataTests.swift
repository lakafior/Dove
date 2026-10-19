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

struct AlbumLibraryTests {
    @Test func guessesArtistAndAlbumFromReleaseNames() {
        let dookie = AlbumGuess(releaseName: "Green Day - Dookie (30th Anniversary Deluxe Edition)  (2023) [24Bit-192kHz] FLAC [PMEDIA] ⭐️")
        #expect(dookie.artist == "Green Day" && dookie.title == "Dookie" && dookie.year == 2023)
        #expect(dookie.key == "music|greenday|dookie")
        let idiot = AlbumGuess(releaseName: "Green Day - American Idiot (20th Anniversary Deluxe Edition) (2024) [24Bit-192kHz] FLAC [PMEDIA] ⭐️")
        #expect(idiot.artist == "Green Day" && idiot.title == "American Idiot")

        let scene = AlbumGuess(releaseName: "Daft_Punk-Discovery-CD-FLAC-2001-PERFECT")
        #expect(scene.artist == "Daft Punk" && scene.title == "Discovery" && scene.year == 2001)
        let web = AlbumGuess(releaseName: "Taco_Hemingway-1-800-OSWIECENIE-WEB-PL-2023-GRP")
        #expect(web.artist == "Taco Hemingway" && web.title.hasPrefix("1"))

        let tidy = AlbumGuess(releaseName: "Radiohead - OK Computer (1997) [MP3 320]")
        #expect(tidy.artist == "Radiohead" && tidy.title == "OK Computer" && tidy.year == 1997)
        let parens = AlbumGuess(releaseName: "Oasis - (What's the Story) Morning Glory (1995) FLAC")
        #expect(parens.title == "(What's the Story) Morning Glory", "parentheses that are part of the title stay")
        let file = AlbumGuess(releaseName: "Kult - Spokojnie.flac")
        #expect(file.artist == "Kult" && file.title == "Spokojnie")
    }

    @Test func matchesTheGuessedAlbumOrNothing() {
        let results = [
            AlbumSummary(id: "mb:1", title: "Dookie Demos", artists: ["Green Day"]),
            AlbumSummary(id: "mb:2", title: "Dookie", artists: ["Green Day"], year: 1994),
            AlbumSummary(id: "mb:3", title: "Dookie", artists: ["Tribute Band"]),
        ]
        let guess = AlbumGuess(releaseName: "Green Day - Dookie (30th Anniversary Deluxe Edition) (2023) FLAC")
        #expect(AlbumMatcher.best(results, for: guess)?.id == "mb:2", "the same title beats a longer one; the reissue's year does not matter")
        #expect(AlbumMatcher.best(results, for: AlbumGuess(title: "Nimrod", artist: "Green Day")) == nil)
        #expect(AlbumMatcher.best([results[2]], for: guess) == nil, "another artist's album of that name is not it")
    }

    @Test func musicIsShelvedByArtistNotWithOtherFiles() {
        func item(_ id: String, _ name: String, added: Double) -> ShelfItem {
            ShelfItem(item: LibraryItem(id: id, backend: .offcloud, name: name, size: 10, status: .ready, addedAt: Date(timeIntervalSince1970: added)), kind: .music)
        }
        let items = [
            item("1", "Green Day - Dookie (30th Anniversary Deluxe Edition) (2023) FLAC", added: 1),
            item("2", "Green Day - American Idiot (2024) FLAC", added: 2),
            item("3", "Green Day - Dookie (1994) [MP3 320]", added: 3),
            item("4", "Kult - Spokojnie (1988) FLAC", added: 0),
            ShelfItem(item: LibraryItem(id: "5", backend: .offcloud, name: "setup.exe", size: 1, status: .ready), kind: .software),
        ]
        let cover = URL(string: "https://img.test/dookie.jpg")!
        let dookie = AlbumSummary(id: "mb:dookie", title: "Dookie", artists: ["Green Day"], year: 1994, cover: cover)
        let albums = LibraryShelf.albums(items, matches: ["music|greenday|dookie": dookie])
        #expect(albums.count == 3)
        #expect(albums.first { $0.id == "album:mb:dookie" }?.items.count == 2, "two releases of one album")

        let artists = LibraryShelf.artists(albums)
        #expect(artists.map(\.name) == ["Green Day", "Kult"])
        #expect(artists[0].albums.map(\.name) == ["American Idiot", "Dookie"] && artists[0].cover == cover)
        #expect(LibraryShelf.others(items).map(\.item.id) == ["5"])

        var filter = LibraryFilter()
        filter.query = "kult"
        #expect(filter.apply(to: albums).map(\.name) == ["Spokojnie"])
        filter.query = ""
        filter.category = .books
        #expect(filter.apply(to: albums).isEmpty)
    }
}

struct MusicTrackNameTests {
    @Test func titlesFromFileNames() {
        #expect(MusicTracks.title(of: "Dookie/01 - Burnout.flac") == "Burnout")
        #expect(MusicTracks.title(of: "CD1/03. Having a Blast.mp3") == "Having a Blast")
        #expect(MusicTracks.title(of: "1-04 Pulling Teeth.flac") == "Pulling Teeth")
        #expect(MusicTracks.title(of: "Green Day - 07 - Basket Case.mp3", artist: "Green Day") == "Basket Case")
        #expect(MusicTracks.title(of: "07 - Green Day - Basket Case.mp3", artist: "Green Day") == "Basket Case")
        #expect(MusicTracks.title(of: "1979.flac") == "1979", "a title that is a number stays")
        #expect(MusicTracks.title(of: "Intro.m4a") == "Intro")

        let files = ["01 - Burnout.flac", "02 - Having a Blast.flac", "03 - Chump.flac"].enumerated().map {
            AudiobookTrack(fileID: "\($0.offset)", path: $0.element)
        }
        #expect(MusicTracks.index(of: AlbumTrack(id: "x", position: 9, title: "Chump"), in: files) == 2, "by title first")
        #expect(MusicTracks.index(of: AlbumTrack(id: "y", position: 2, title: "Having A Blast (Remastered)"), in: files) == 1, "else by position")
        #expect(MusicTracks.index(of: AlbumTrack(id: "z", position: 9, title: "Nope"), in: files) == nil)
    }
}

struct MusicFormatTests {
    @Test func formatsFromReleaseNames() {
        #expect(MusicFileFormat.formats(in: "Green Day - Dookie (30th Anniversary Deluxe Edition)  (2023) [24Bit-192kHz] FLAC [PMEDIA] ⭐️") == [.hiRes, .flac])
        #expect(MusicFileFormat.formats(in: "Daft_Punk-Discovery-CD-FLAC-2001-PERFECT") == [.flac])
        #expect(MusicFileFormat.formats(in: "Radiohead - OK Computer (1997) [MP3 320]") == [.mp3])
        #expect(MusicFileFormat.formats(in: "Artist - Album (2020) WEB 320kbps") == [.mp3])
        #expect(MusicFileFormat.formats(in: "Pink Floyd - Wish You Were Here (SACD DSD64)") == [.dsd])
        #expect(MusicFileFormat.formats(in: "Artist - Album [24-96 ALAC]") == [.hiRes, .alac])
        #expect(MusicFileFormat.formats(in: "Artist - Album (Hi-Res) [M4A]") == [.hiRes, .aac])
        #expect(MusicFileFormat.formats(in: "Artist - Album 2024") == [], "a year is no format")
        #expect(MusicFileFormat.formats(in: "Blink-182 - Enema of the State") == [], "a band named after a number is no format")
    }
}
