import Foundation
import Testing
@testable import DoveKit

struct DownloadGroupTests {
    private func plugin(_ fileID: String, bytes: Int64 = 50, total: Int64? = 100, state: DownloadRecord.State = .downloading, folder: String? = nil) -> DownloadRecord {
        DownloadRecord(
            backend: nil, plugin: PluginFileRef(pluginID: "wolnelektury.books", fileID: fileID), itemID: "", fileID: fileID,
            name: "\(fileID).mp3", state: state, bytesWritten: bytes, totalBytes: total, subfolder: folder
        )
    }

    @Test func filesOfOneReleaseAreOneRow() {
        let folder = "Audiobooks/Adam Mickiewicz/Pan Tadeusz"
        let records = [
            plugin("pan-tadeusz#0", folder: folder),
            plugin("lalka.epub"),
            plugin("pan-tadeusz#1", bytes: 100, state: .finished, folder: folder),
            plugin("pan-tadeusz#2", bytes: 0, total: nil, state: .paused, folder: folder),
            DownloadRecord(backend: .offcloud, itemID: "cloud:1", fileID: "a", name: "01.flac", bytesWritten: 10, totalBytes: 10),
            DownloadRecord(backend: .offcloud, itemID: "cloud:1", fileID: "b", name: "02.flac", bytesWritten: 10, totalBytes: 10),
            DownloadRecord(backend: .offcloud, itemID: "cloud:2", fileID: "c", name: "movie.mkv"),
        ]
        let groups = DownloadGroup.make(records)
        #expect(groups.map(\.records.count) == [3, 1, 2, 1], "a release's files together where the first one was; lone files stay rows")

        let book = groups[0]
        #expect(book.id == "plugin:wolnelektury.books:pan-tadeusz" && book.title == "Pan Tadeusz")
        #expect(book.state == .downloading && book.finishedCount == 1)
        #expect(book.totalBytes == nil && book.progress == nil, "one file's size is unknown")
        #expect(groups[1].isSingle && groups[1].title == "lalka.epub.mp3")

        let album = groups[2]
        #expect(album.title == "01.flac and 1 more" && album.progress == 1 && album.state == .downloading)

        let failed = DownloadGroup.make([plugin("x#0", state: .failed(reason: "gone")), plugin("x#1", state: .finished)])
        #expect(failed.first?.state == .failed(reason: "gone"))
    }
}
