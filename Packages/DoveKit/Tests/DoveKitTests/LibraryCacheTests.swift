import Foundation
import Testing
@testable import DoveKit

struct LibraryCacheTests {
    private func item(_ id: String, _ backend: BackendID, daysAgo: Double, status: LibraryItem.Status = .ready) -> LibraryItem {
        LibraryItem(
            id: id,
            backend: backend,
            name: "Show.S01E0\(id.suffix(1)).1080p",
            size: 1_000,
            status: status,
            files: [LibraryFile(id: "1", name: "a.mkv", size: 900)],
            addedAt: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400),
            infoHash: String(repeating: "a", count: 40)
        )
    }

    @Test func roundTripsItemsWithEveryStatus() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "dove-tests/\(UUID().uuidString)/library.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let items = [
            item("t1", .torBox, daysAgo: 1),
            item("t2", .torBox, daysAgo: 2, status: .downloading(progress: 0.4)),
            item("r1", .realDebrid, daysAgo: 3, status: .failed(reason: "dead")),
            item("r2", .realDebrid, daysAgo: 4, status: .awaitingFileSelection),
        ]

        try LibraryCache(items: items).save(to: url)
        let loaded = try #require(LibraryCache.load(from: url))

        #expect(loaded.items == items)
    }

    @Test func ignoresAMissingOrForeignFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "dove-tests/\(UUID().uuidString).json")
        #expect(LibraryCache.load(from: url) == nil)
        try Data(#"{"something":"else"}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(LibraryCache.load(from: url) == nil)
    }

    @Test func keepsCachedItemsOnlyForServicesThatFailedAndAreStillSetUp() {
        let cached = [item("t1", .torBox, daysAgo: 1), item("r1", .realDebrid, daysAgo: 2), item("o1", .offcloud, daysAgo: 3)]
        let fresh = [item("t9", .torBox, daysAgo: 0)]

        let merged = LibraryCache.merge(
            fresh: fresh,
            cached: cached,
            failed: [.realDebrid, .offcloud],
            configured: [.torBox, .realDebrid]
        )

        // TorBox answered (its old item is gone), Real-Debrid timed out (kept), Offcloud's key was removed.
        #expect(merged.map(\.id) == ["t9", "r1"])
    }
}
