import Foundation
import Testing
@testable import DoveKit

struct FolderBackendTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func theLayoutGivesKindAuthorAndTitle() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("book", to: root.appending(path: "Books/Andy Weir/Project Hail Mary/Project Hail Mary - Andy Weir.epub"))
        try write("pdf", to: root.appending(path: "Books/Andy Weir/Project Hail Mary/Project Hail Mary - Andy Weir.pdf"))
        try write("one", to: root.appending(path: "Audiobooks/Stanisław Lem/Solaris/CD1/01.mp3"))
        try write("two", to: root.appending(path: "Audiobooks/Stanisław Lem/Solaris/CD1/02.mp3"))
        try write("", to: root.appending(path: "Audiobooks/Stanisław Lem/Solaris/.DS_Store"))
        try write("", to: root.appending(path: "Books/Frank Herbert/.Dune.epub.icloud"))
        try write("x", to: root.appending(path: "Software/Tool v2.dmg"))
        try write("old", to: root.appending(path: "Old Flat Download.epub"))

        let backend = FolderBackend(directory: root)
        let items = try await backend.items()
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        #expect(Set(byID.keys) == [
            "folder:Books/Andy Weir/Project Hail Mary", "folder:Audiobooks/Stanisław Lem/Solaris",
            "folder:Books/Frank Herbert/Dune.epub", "folder:Software/Tool v2.dmg", "folder:Old Flat Download.epub",
        ])
        let book = try #require(byID["folder:Books/Andy Weir/Project Hail Mary"])
        #expect(book.name == "Andy Weir - Project Hail Mary" && book.kindHint == .books)
        #expect(book.files.map(\.id) == ["Project Hail Mary - Andy Weir.epub", "Project Hail Mary - Andy Weir.pdf"])
        #expect(ShelfItem(item: book).bookGuess?.author == "Andy Weir", "the name reads back as author and title")
        let audiobook = try #require(byID["folder:Audiobooks/Stanisław Lem/Solaris"])
        #expect(audiobook.kindHint == .audiobooks && ShelfItem(item: audiobook).kind == .audiobooks)
        #expect(audiobook.files.map(\.id) == ["CD1/01.mp3", "CD1/02.mp3"], "hidden files skipped")
        #expect(byID["folder:Books/Frank Herbert/Dune.epub"]?.name == "Frank Herbert - Dune", "a placeholder under its real name")
        #expect(byID["folder:Software/Tool v2.dmg"]?.kindHint == .software)
        #expect(byID["folder:Old Flat Download.epub"]?.kindHint == nil, "downloads from before the layout stay listed")

        let request = try await backend.downloadRequest(itemID: "folder:Audiobooks/Stanisław Lem/Solaris", fileID: "CD1/02.mp3")
        #expect(request.url == root.appending(path: "Audiobooks/Stanisław Lem/Solaris/CD1/02.mp3"))
        let single = try await backend.downloadRequest(itemID: "folder:Software/Tool v2.dmg", fileID: "Tool v2.dmg")
        #expect(single.url == root.appending(path: "Software/Tool v2.dmg"))
    }

    @Test func placementsFollowTheLayout() {
        let book = BookSummary(id: "ol:1", title: "Project Hail Mary: A Novel", authors: ["Andy Weir"])
        let fromBook = LibraryFolderLayout.placement(kind: .books, book: book, itemName: "x", fileName: "any name.EPUB", singleFile: true)
        #expect(fromBook == .init(folder: "Books/Andy Weir/Project Hail Mary", fileName: "Project Hail Mary - Andy Weir.epub"))

        let shadow = LibraryFolderLayout.placement(
            kind: .books, itemName: "",
            fileName: "Solaris -- Stanisław Lem; Joanna Kilmartin -- 1961 -- Faber -- 9780571 -- d6e1dc51 -- Anna’s Archive.epub",
            singleFile: true
        )
        #expect(shadow == .init(folder: "Books/Stanisław Lem/Solaris", fileName: "Solaris - Stanisław Lem.epub"))

        let audiobook = LibraryFolderLayout.placement(
            kind: .audiobooks, itemName: "Andy Weir - Project Hail Mary (Unabridged)", fileName: "CD1/01.mp3", singleFile: false
        )
        #expect(audiobook.folder.hasPrefix("Audiobooks/Andy Weir/Project Hail Mary") && audiobook.fileName == "CD1/01.mp3")

        let unknown = LibraryFolderLayout.placement(kind: .books, itemName: "", fileName: "Dune.epub", singleFile: true)
        #expect(unknown.folder == "Books/Unknown Author/Dune")
        #expect(LibraryFolderLayout.placement(kind: .video, itemName: "Movie.2023.1080p", fileName: "m.mkv", singleFile: false)
            == .init(folder: "Video/Movie.2023.1080p", fileName: "m.mkv"))
        #expect(LibraryFolderLayout.component("../a/b: c") == "-a-b - c")
    }

    @Test func deletesStayInsideTheFolder() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("x", to: root.appending(path: "Book.epub"))
        try write("", to: root.appending(path: ".Gone.pdf.icloud"))
        try write("y", to: root.appending(path: "Books/A/T/T - A.epub"))
        let backend = FolderBackend(directory: root)

        try await backend.delete("folder:Book.epub")
        try await backend.delete("folder:Gone.pdf")
        try await backend.delete("folder:Books/A/T")
        #expect(try await backend.items().isEmpty)
        await #expect(throws: BackendError.notFound) { try await backend.delete("folder:Books/../..") }
        await #expect(throws: BackendError.notFound) { try await backend.delete("folder:..") }
        await #expect(throws: BackendError.unsupportedSource(.torrent)) { try await backend.add(.magnet(infoHash: String(repeating: "a", count: 40), name: nil)) }
    }

    @Test func iCloudDriveIsAPlaceNotAService() {
        #expect(BackendID.iCloudDrive.isStorage && !BackendID.iCloudDrive.isUsenet)
        #expect(!SharedConfiguration.debrids.contains(.iCloudDrive))
        #expect(FolderBackend(directory: URL(filePath: "/tmp")).supportedSources.isEmpty, "the router never picks it")
        #expect(OffcloudBackend(apiKey: "k").acceptsDirectLinks && TorBoxBackend(apiKey: "k").acceptsDirectLinks)
        #expect(PremiumizeBackend(apiKey: "k").acceptsDirectLinks)
        #expect(!RealDebridBackend(apiKey: "k").acceptsDirectLinks && !AllDebridBackend(apiKey: "k").acceptsDirectLinks)
        #expect(!DebridLinkBackend(apiKey: "k").acceptsDirectLinks)
    }
}

struct DownloadDestinationTests {
    @Test func defaultsByKindAndChoices() throws {
        var destinations = DownloadDestinations()
        #expect(destinations.place(for: .books) == .iCloud)
        #expect(destinations.place(for: .audiobooks) == .iCloud)
        #expect(destinations.place(for: .video) == .device)
        destinations.set(.device, for: .books)
        destinations.set(.device, for: .video)
        destinations.set(.service(.offcloud), for: .software)
        #expect(destinations.place(for: .books) == .device)
        #expect(destinations.chosen == ["books": .device, "software": .service(.offcloud)], "a choice equal to the default is not stored")

        let saved = try JSONEncoder().encode(destinations)
        #expect(String(decoding: saved, as: UTF8.self).contains(#""service:offcloud""#))
        #expect(try JSONDecoder().decode(DownloadDestinations.self, from: saved) == destinations)
        let older = Data(#"{"chosen":{"books":"device","music":"somewhere-new"}}"#.utf8)
        #expect(try JSONDecoder().decode(DownloadDestinations.self, from: older).chosen == ["books": .device],
                "a place this build does not know falls back to the default")
        #expect(FilePlace(rawValue: "service:torBox") == .service(.torBox) && FilePlace(rawValue: "service:nope") == nil)
        #expect(SearchCategory.audiobooks.contentKind == .audiobooks && SearchCategory.media.contentKind == .video)

        let old = Data(#"{"id":"1","backend":"torBox","itemID":"i","fileID":"f","name":"a.mkv","state":{"finished":{}},"bytesWritten":1,"createdAt":0}"#.utf8)
        #expect(try JSONDecoder().decode(DownloadRecord.self, from: old).destination == .device, "older records were on the device")
    }

    @Test @MainActor func iCloudDownloadsFallBackToTheDeviceWithoutICloud() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "dest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = DownloadManager(
            configuration: .ephemeral, directory: directory, store: DownloadStore(directory: directory.appending(path: "store"))
        )
        let ref = PluginFileRef(pluginID: "annas-archive.download", fileID: "d6e1dc51a50726f00ec438af21952a45")
        let request = URLRequest(url: URL(string: "https://cdn.invalid/file.epub")!)
        let device = try manager.start(request, plugin: ref, name: "Book.epub")
        let cloud = try manager.start(request, plugin: ref, name: "Book.epub", destination: .iCloud)
        #expect(device != cloud, "the same file may go to both places")
        #expect(manager[cloud]?.destination == .iCloud && manager[cloud]?.plugin == ref)

        // Records from before plugins replaced direct downloads still read (key `direct`, `sourceID`/`md5`).
        let old = Data(#"{"id":"1","direct":{"sourceID":"plugin:annas-archive.download","md5":"abc#2"},"itemID":"direct:abc","fileID":"abc","name":"a.epub","state":{"paused":{}},"bytesWritten":0,"createdAt":0}"#.utf8)
        let record = try JSONDecoder().decode(DownloadRecord.self, from: old)
        #expect(record.plugin == PluginFileRef(pluginID: "annas-archive.download", fileID: "abc#2") && record.backend == nil)
        let again = try JSONDecoder().decode(DownloadRecord.self, from: JSONEncoder().encode(record))
        #expect(again.plugin == record.plugin)
        manager.remove(device)
        manager.remove(cloud)
    }
}
