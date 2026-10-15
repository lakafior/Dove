import Foundation
import Testing
@testable import DoveKit

struct LibraryNamingTests {
    @Test(arguments: [
        "1a07d876aaaebe797c21eff39df7436d2f739b7a",
        "a8Fk2LmQ9zXw31Pd.mkv",
        "3f2b6c1e-9d4a-4b7e-8c21-5a6f0e9d1b23",
        "kD9fj3LsP0qWm2Xv.part01.rar",
        "",
    ])
    func randomNamesAreObfuscated(_ name: String) {
        #expect(LibraryNaming.looksObfuscated(name))
    }

    @Test(arguments: [
        "Dune.Part.Two.2024.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX",
        "Severance S02E05 1080p",
        "Interstellar.mkv",
        "TheGodfather1972",
        "Ubuntu 24.04 Desktop",
        "Shogun.S01E01.mkv",
    ])
    func releaseNamesAreNot(_ name: String) {
        #expect(!LibraryNaming.looksObfuscated(name))
    }

    @Test func readableServiceNameWins() {
        // A search row can name one episode of the pack it added: the service's own name is better.
        let item = LibraryItem(id: "torrent:1", backend: .torBox, name: "Shogun.S01.1080p.WEB", status: .ready)
        let hint = AddedHint(releaseName: "Shogun.S01E01.1080p.WEB.mkv")
        #expect(LibraryNaming.readableName(of: item, hint: hint) == "Shogun.S01.1080p.WEB")
    }

    @Test func obfuscatedNameTakesTheHint() {
        let item = LibraryItem(id: "torrent:1", backend: .realDebrid, name: "a8Fk2LmQ9zXw31Pd", status: .ready)
        let hint = AddedHint(releaseName: "Dune.2021.2160p.WEB-DL")
        #expect(LibraryNaming.readableName(of: item, hint: hint) == "Dune.2021.2160p.WEB-DL")
    }

    @Test func obfuscatedNameWithoutHintTakesTheFiles() {
        let single = LibraryItem(id: "1", backend: .torBox, name: "a8Fk2LmQ9zXw31Pd", status: .ready, files: [
            LibraryFile(id: "1", name: "a8Fk2LmQ9zXw31Pd/Arrival.2016.1080p.BluRay.mkv", size: 9_000),
            LibraryFile(id: "2", name: "a8Fk2LmQ9zXw31Pd/sample.mkv", size: 10),
        ])
        #expect(LibraryNaming.readableName(of: single, hint: nil) == "Arrival.2016.1080p.BluRay.mkv")

        let pack = LibraryItem(id: "2", backend: .torBox, name: "kD9fj3LsP0qWm2Xv", status: .ready, files: [
            LibraryFile(id: "1", name: "Severance.S01.1080p/Severance.S01E01.mkv"),
            LibraryFile(id: "2", name: "Severance.S01.1080p/Severance.S01E02.mkv"),
        ])
        #expect(LibraryNaming.readableName(of: pack, hint: nil) == "Severance.S01.1080p")

        let random = LibraryItem(id: "3", backend: .torBox, name: "kD9fj3LsP0qWm2Xv", status: .ready, files: [
            LibraryFile(id: "1", name: "x8Yd2kLq0PmZ7wRt.mkv"),
        ])
        #expect(LibraryNaming.readableName(of: random, hint: nil) == "kD9fj3LsP0qWm2Xv")
    }
}

struct AddedHintsTests {
    private let dune = MediaSummary(id: "tt1160419", type: .movie, name: "Dune", releaseInfo: "2021")
    private let hash = "1a07d876aaaebe797c21eff39df7436d2f739b7a"

    @Test func shelfItemGuessesFromTheHint() {
        let item = LibraryItem(id: "torrent:9", backend: .realDebrid, name: "a8Fk2LmQ9zXw31Pd", status: .ready)
        let shelf = ShelfItem(item: item, hint: AddedHint(releaseName: "Dune.2021.2160p.WEB-DL"))
        #expect(shelf.name == "Dune.2021.2160p.WEB-DL")
        #expect(shelf.isRenamed)
        #expect(shelf.guess.title == "Dune")
        #expect(shelf.guess.year == 2021)
        #expect(shelf.kind == .video)
    }

    @Test func mediaAloneMakesItVideo() {
        let item = LibraryItem(id: "torrent:9", backend: .realDebrid, name: "a8Fk2LmQ9zXw31Pd", status: .ready)
        let shelf = ShelfItem(item: item, hint: AddedHint(releaseName: nil, media: dune))
        #expect(shelf.kind == .video)
        #expect(shelf.guess.key == ReleaseParser.guess("Dune 2021").key)
    }

    /// Reinsert and Move give the item a new ID on the same hash.
    @Test func hintFollowsTheInfoHash() {
        var hints = AddedHints()
        hints.record(AddedHint(releaseName: "Dune.2021"), backend: .torBox, itemIDs: ["torrent:1"], infoHash: hash.uppercased())
        let moved = LibraryItem(id: "torrent:2", backend: .offcloud, name: "x", status: .ready, infoHash: hash)
        #expect(hints.hint(for: moved)?.releaseName == "Dune.2021")
        let byID = LibraryItem(id: "torrent:1", backend: .torBox, name: "x", status: .ready)
        #expect(hints.hint(for: byID)?.releaseName == "Dune.2021")
        #expect(hints.hint(for: LibraryItem(id: "torrent:1", backend: .realDebrid, name: "x", status: .ready)) == nil)
    }

    @Test func emptyHintsAreNotKept() {
        var hints = AddedHints()
        hints.record(AddedHint(releaseName: "  "), backend: .torBox, itemIDs: ["torrent:1"], infoHash: hash)
        #expect(hints == AddedHints())
    }

    @Test func oldHintsArePruned() {
        var hints = AddedHints()
        hints.record(AddedHint(releaseName: "Old", addedAt: Date(timeIntervalSinceNow: -AddedHints.maxAge - 60)), backend: .torBox, itemIDs: ["a"], infoHash: nil)
        hints.record(AddedHint(releaseName: "New"), backend: .torBox, itemIDs: ["b"], infoHash: nil)
        hints.prune()
        #expect(Array(hints.byItem.values.compactMap(\.releaseName)) == ["New"])
    }

    @Test func savesAndLoads() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hints-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var hints = AddedHints()
        hints.record(AddedHint(releaseName: "Dune.2021", media: dune), backend: .torBox, itemIDs: ["torrent:1"], infoHash: hash)
        try hints.save(to: url)
        #expect(AddedHints.load(from: url)?.byHash[hash]?.media == dune)
    }

    @Test func hintsSetTheMatchButKeepTheUsersChoice() async {
        let store = MatchStore(fileURL: nil)
        let item = LibraryItem(id: "torrent:9", backend: .realDebrid, name: "a8Fk2LmQ9zXw31Pd", status: .ready)
        let shelf = ShelfItem(item: item, hint: AddedHint(releaseName: "Dune.2021.2160p", media: dune))

        let applied = await LibraryMatcher.applyHints([shelf], store: store)
        #expect(applied[shelf.guess.key] == dune)
        #expect(await store.entry(for: shelf.guess.key) == .matched(dune))

        let mine = MediaSummary(id: "tt0087182", type: .movie, name: "Dune", releaseInfo: "1984")
        await store.set(.manual(mine), for: shelf.guess.key)
        #expect(await LibraryMatcher.applyHints([shelf], store: store).isEmpty)
        #expect(await store.entry(for: shelf.guess.key) == .manual(mine))
    }
}

struct ReleaseNameSourceTests {
    @Test func magnetCarriesTheReleaseName() {
        let candidate = StreamCandidate(
            id: "1", kind: .p2p, title: "Dune.2021.mkv", folderName: "Dune (2021) [2160p]",
            infoHash: "1A07D876AAAEBE797C21EFF39DF7436D2F739B7A"
        )
        #expect(candidate.librarySource == .magnet(
            "magnet:?xt=urn:btih:1a07d876aaaebe797c21eff39df7436d2f739b7a&dn=Dune%20%282021%29%20%5B2160p%5D"
        ))
        #expect(candidate.librarySource?.displayName == "Dune (2021) [2160p]")
    }

    @Test func placeholderTitleIsNoName() {
        let candidate = StreamCandidate(id: "1", kind: .p2p, title: "Stream", infoHash: "1a07d876aaaebe797c21eff39df7436d2f739b7a")
        #expect(candidate.releaseName == nil)
        #expect(candidate.librarySource == .magnet("magnet:?xt=urn:btih:1a07d876aaaebe797c21eff39df7436d2f739b7a"))
    }

    @Test func nzbCarriesTheIndexerTitle() {
        let url = URL(string: "https://indexer.example/get/1")!
        let candidate = StreamCandidate(id: "newznab:1", kind: .usenet, title: "Dune.2021.2160p.WEB-DL", nzbURL: url)
        #expect(candidate.librarySource == .nzbURL(url, name: "Dune.2021.2160p.WEB-DL"))
    }
}
