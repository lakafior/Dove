import Foundation
import Testing
@testable import DoveKit

struct SourceSelectionTests {
    private let indexers = [
        NewznabIndexer(id: "geek", name: "Geek", url: URL(string: "https://geek.example")!, apiKey: "k"),
        NewznabIndexer(id: "jackett", kind: .torznab, name: "Jackett", url: URL(string: "https://jackett.example")!, apiKey: "k"),
        NewznabIndexer(id: "off", name: "Off", url: URL(string: "https://off.example")!, apiKey: "k", enabled: false),
    ]

    @Test func everythingStartsOnAndChoicesStayInTheirCategory() {
        var selection = SourceSelection()
        #expect(selection.indexerIDs(in: .books, from: indexers) == ["geek", "jackett"], "disabled in Settings stays out")
        #expect(selection.asksAddons(in: .media))
        #expect(!selection.asksAddons(in: .books), "addons cannot search books")

        selection.set("geek", on: false, in: .books)
        selection.set(SourceSelection.addons, on: false, in: .media)
        #expect(selection.indexerIDs(in: .books, from: indexers) == ["jackett"])
        #expect(selection.indexerIDs(in: .media, from: indexers) == ["geek", "jackett"])
        #expect(!selection.asksAddons(in: .media))
        #expect(selection.count(in: .media, indexers: indexers) == (2, 3))
        #expect(selection.count(in: .books, indexers: indexers) == (1, 2))

        selection.set("geek", on: true, in: .books)
        #expect(selection.indexerIDs(in: .books, from: indexers) == ["geek", "jackett"])
    }

    @Test func roundTripsAndReadsOldCategoryNames() throws {
        var selection = SourceSelection()
        selection.set("geek", on: false, in: .music)
        let data = try JSONEncoder().encode(selection)
        #expect(try JSONDecoder().decode(SourceSelection.self, from: data) == selection)
        #expect(try JSONDecoder().decode(SourceSelection.self, from: Data("{}".utf8)) == SourceSelection())

        let categories = try JSONDecoder().decode([SearchCategory].self, from: Data(#"["media","other","books","future"]"#.utf8))
        #expect(categories == [.media, .all, .books, .media])
    }
}
