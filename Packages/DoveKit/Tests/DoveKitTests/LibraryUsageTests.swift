import Foundation
import Testing
@testable import DoveKit

struct LibraryUsageTests {
    private func shelf(_ id: String, size: Int64?, files: [LibraryFile] = []) -> ShelfItem {
        ShelfItem(item: LibraryItem(id: id, backend: .torBox, name: "Release.\(id).1080p", size: size, status: .ready, files: files))
    }

    @Test func sumsSizesFallingBackToFiles() {
        let usage = LibraryUsage([
            shelf("a", size: 1_000),
            shelf("files", size: nil, files: [LibraryFile(id: "1", name: "a.mkv", size: 700), LibraryFile(id: "2", name: "b.nfo")]),
            shelf("none", size: nil),
        ])
        #expect(usage.items == 3)
        #expect(usage.bytes == 1_700)
    }

    @Test func emptyLibrary() {
        #expect(LibraryUsage([]) == LibraryUsage([]))
        #expect(LibraryUsage([]).bytes == 0)
    }
}
