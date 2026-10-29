#if DEBUG
import Foundation
import Testing
@testable import DoveKit

@Suite("Demo content")
struct DemoTests {
    @Test func shelfClassifiesDemoLibrary() async throws {
        let items = try await DemoBackend().items().map { ShelfItem(item: $0) }
        let titles = LibraryShelf.titles(items, matches: [:])
        #expect(titles.filter { $0.type == .movie }.count == 6)
        #expect(titles.filter { $0.type == .series }.count == 1)
        #expect(titles.first { $0.name == "Nosferatu" }?.year == "1922")
        #expect(titles.first { $0.name.contains("Beverly Hillbillies") }?.items.first?.item.files.count == 4)
        let books = LibraryShelf.books(items, matches: [:])
        #expect(books.filter { $0.format == .ebook }.count == 4)
        #expect(books.filter { $0.format == .audiobook }.count == 2)
        #expect(LibraryShelf.albums(items, matches: [:]).count == 2)
    }

    @Test func addonServesCatalogMetaAndStreams() async throws {
        let addon = try await StremioAddon.load(manifestURL: DemoCatalog.addonURL, transport: DemoTransport())
        #expect(addon.manifest.id == "net.smigi.dove.demo")
        #expect(try await addon.search("nosferatu", type: .movie).contains { $0.id == "tt0013442" })
        let meta = try await addon.meta(type: .series, id: "tt0055662")
        #expect(meta.episodes.count == 4)
        for film in DemoCatalog.films {
            let streams = try await addon.streams(type: .movie, id: film.summary.id)
            #expect((4...6).contains(streams.count))
            #expect(
                streams.allSatisfy {
                    ReleaseParser.parse($0.title).resolution != nil && $0.size != nil && $0.seeders != nil
                }
            )
            let cached = try await DemoBackend().cachedHashes(streams.compactMap(\.infoHash))
            #expect(!cached.isEmpty && cached.count < streams.count)
        }
        for episode in DemoCatalog.series.episodes {
            let streams = try await addon.streams(type: .series, id: episode.id)
            #expect((4...6).contains(streams.count))
            #expect(
                streams.allSatisfy {
                    ReleaseParser.parse($0.title).resolution != nil && $0.size != nil && $0.seeders != nil
                }
            )
        }
    }

    @Test func serverRejectsOtherHosts() {
        let request = URLRequest(url: URL(string: "https://example.com/manifest.json")!)
        let (_, response) = DemoServer.respond(to: request)
        #expect(response.statusCode == 503)
    }
}
#endif
