import Foundation
import Testing
@testable import DoveKit

struct PickedFoldersTests {
    @Test func folderDestinationIsOneString() throws {
        let place = FilePlace.download(.folder("A1-B2"))
        #expect(place.rawValue == "folder:A1-B2")
        #expect(FilePlace(rawValue: "folder:A1-B2") == place)
        #expect(DownloadDestination(rawValue: "folder:") == nil)
        let data = try JSONEncoder().encode(DownloadDestinations(chosen: ["video": place]))
        #expect(try JSONDecoder().decode(DownloadDestinations.self, from: data).place(for: .video) == place)
        // Records written before folders keep their destinations.
        #expect(try JSONDecoder().decode([DownloadDestination].self, from: Data(#"["device","iCloud"]"#.utf8)) == [.device, .iCloud])
    }

    @Test func addResolveRemove() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "dove-picked-\(UUID().uuidString)")
        let target = root.appending(path: "Movies")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = PickedFolders(fileURL: root.appending(path: "folders.json"))
        let folder = try store.add(target)
        #expect(folder.name == "Movies")
        // Choosing the same folder again gives the same entry.
        #expect(try store.add(target).id == folder.id)
        #expect(store.all.count == 1)
        #expect(store.resolve(folder.id)?.standardizedFileURL.path == target.standardizedFileURL.path)

        // A new launch reads the file and still reaches the folder.
        let again = PickedFolders(fileURL: root.appending(path: "folders.json"))
        #expect(again.resolve(folder.id) != nil)

        store.remove(folder.id)
        #expect(store.resolve(folder.id) == nil && store.all.isEmpty)
    }

    @Test func missingFolderIsNotReachable() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "dove-picked-\(UUID().uuidString)")
        let target = root.appending(path: "Disk")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = PickedFolders(fileURL: root.appending(path: "folders.json"))
        let folder = try store.add(target)
        try FileManager.default.removeItem(at: target)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!store.isReachable(folder.id))
        #expect(store.folder(folder.id) != nil)
    }
}
