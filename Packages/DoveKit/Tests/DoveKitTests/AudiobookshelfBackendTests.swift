import Foundation
import Testing
@testable import DoveKit

struct AudiobookshelfBackendTests {
    private let server = URL(string: "http://192.168.1.10:13378/audiobookshelf")!

    private let libraries = """
    {"libraries": [
      {"id": "lib-books", "name": "Audiobooks", "mediaType": "book", "folders": [{"id": "fol-1", "fullPath": "/audiobooks"}]},
      {"id": "lib-pods", "name": "Podcasts", "mediaType": "podcast", "folders": [{"id": "fol-2", "fullPath": "/podcasts"}]}
    ]}
    """

    private let page = """
    {"results": [
      {"id": "li-1", "mediaType": "book", "addedAt": 1700000000000, "updatedAt": 1700000500000, "size": 512000000,
       "media": {"metadata": {"title": "Project Hail Mary", "authorName": "Andy Weir", "publishedYear": "2021",
                              "description": "<p>A lone astronaut.</p>"},
                 "coverPath": "/metadata/items/li-1/cover.jpg", "numTracks": 12, "ebookFormat": null}},
      {"id": "li-2", "mediaType": "book", "addedAt": 1600000000000,
       "media": {"metadata": {"title": "Solaris", "authorName": "Stanisław Lem, Bill Johnston"},
                 "coverPath": null, "numTracks": 0, "ebookFormat": "epub"}},
      {"id": "li-3", "mediaType": "book", "isMissing": true, "media": {"metadata": {"title": "Gone"}, "numTracks": 3}}
    ], "total": 3, "limit": 500, "page": 0}
    """

    private func stubbed(me: String = #"{"username": "mar", "type": "user", "permissions": {"download": true, "upload": true}}"#) async -> MockTransport {
        let transport = MockTransport()
        await transport.stub("api/me", json: me)
        await transport.stub("api/libraries", json: libraries)
        await transport.stub("api/libraries/lib-books/items", json: page)
        return transport
    }

    @Test func listsBookLibrariesWithTheServersMetadata() async throws {
        let transport = await stubbed()
        let backend = AudiobookshelfBackend(baseURL: server, token: "key", transport: transport)
        let items = try await backend.items()

        #expect(items.map(\.id) == ["abs:li-1", "abs:li-2"])
        let book = items[0]
        #expect(book.backend == .audiobookshelf)
        #expect(book.name == "Andy Weir - Project Hail Mary")
        #expect(book.kindHint == .audiobooks)
        #expect(book.size == 512_000_000)
        #expect(book.addedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(book.book?.year == 2021)
        #expect(book.book?.description == "A lone astronaut.")
        #expect(book.book?.cover?.absoluteString == "audiobookshelf://cover/li-1?v=1700000500000")
        #expect(items[1].kindHint == .books)
        #expect(items[1].book?.authors == ["Stanisław Lem", "Bill Johnston"])
        #expect(items[1].book?.cover == nil)

        let requests = await transport.requests
        #expect(!requests.contains { $0.url!.path.contains("lib-pods") })
        let list = try #require(requests.first { $0.url!.path.hasSuffix("lib-books/items") })
        #expect(list.url!.path == "/audiobookshelf/api/libraries/lib-books/items")
        #expect(list.url!.query!.contains("minified=1"))
        #expect(list.value(forHTTPHeaderField: "Authorization") == "Bearer key")
    }

    @Test func readsFilesFromTheExpandedItem() async throws {
        let transport = MockTransport()
        await transport.stub("api/items/li-1", json: """
        {"id": "li-1", "mediaType": "book", "media": {"metadata": {"title": "Project Hail Mary", "authorName": "Andy Weir"},
          "coverPath": null, "numTracks": 2},
         "libraryFiles": [
          {"ino": "11", "fileType": "audio", "metadata": {"filename": "01.mp3", "relPath": "CD1/01.mp3", "size": 1000}},
          {"ino": "12", "fileType": "audio", "metadata": {"filename": "01.mp3", "relPath": "CD2/01.mp3", "size": 2000}},
          {"ino": "13", "fileType": "metadata", "metadata": {"filename": "metadata.json", "relPath": "metadata.json", "size": 10}}
         ]}
        """)
        let backend = AudiobookshelfBackend(baseURL: server, token: "key", transport: transport)
        let item = try await backend.item("abs:li-1")

        #expect(item.files.map(\.id) == ["11", "12"])
        #expect(item.files.map(\.name) == ["CD1/01.mp3", "CD2/01.mp3"])
        #expect(item.files[1].size == 2000)
        #expect(try await transport.requests.first?.url?.query == "expanded=1")

        let download = try await backend.downloadRequest(itemID: "abs:li-1", fileID: "12")
        #expect(download.url!.absoluteString == "http://192.168.1.10:13378/audiobookshelf/api/items/li-1/file/12/download")
        #expect(download.value(forHTTPHeaderField: "Authorization") == "Bearer key")

        let cover = try await backend.coverRequest(for: URL(string: "audiobookshelf://cover/li-1?v=5")!)
        #expect(cover.url!.path == "/audiobookshelf/api/items/li-1/cover")
        #expect(cover.url!.query!.contains("width=400"))
    }

    @Test func refusesToSendWithoutTheUploadPermission() async throws {
        let transport = await stubbed(me: #"{"username": "anna", "type": "user", "permissions": {"download": true, "upload": false}}"#)
        let backend = AudiobookshelfBackend(baseURL: server, token: "key", transport: transport)

        let account = try await backend.account()
        #expect(account.canUpload == false)
        #expect(account.bookLibraries.map(\.id) == ["lib-books"])
        await #expect(throws: BackendError.api(message: "This Audiobookshelf account may not upload. Turn on \"Can Upload\" for anna in Audiobookshelf › Settings › Users.")) {
            try await backend.uploadTarget()
        }
        // The server goes by the flag alone, root included.
        let root = await stubbed(me: #"{"username": "root", "type": "root", "permissions": {"upload": true}}"#)
        #expect(try await AudiobookshelfBackend(baseURL: server, token: "key", transport: root).account().canUpload)
    }

    @Test func picksTheChosenLibraryAndAsksWhetherTheFolderIsFree() async throws {
        let transport = await stubbed()
        await transport.stub("api/filesystem/pathexists", json: #"{"exists": true, "libraryItemTitle": "Project Hail Mary"}"#)
        let backend = AudiobookshelfBackend(baseURL: server, token: "key", libraryID: "lib-books", transport: transport)

        let target = try await backend.uploadTarget()
        #expect(target.library.id == "lib-books")
        #expect(target.folder.fullPath == "/audiobooks")
        let answer = try await backend.pathExists(title: "Project Hail Mary: Deluxe", author: "Andy Weir", series: nil, folder: target.folder)
        #expect(answer.exists)
        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "POST")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
        #expect(body == ["directory": "Andy Weir/Project Hail Mary Deluxe", "folderPath": "/audiobooks"])
    }

    @Test func explainsRefusalsInWords() async throws {
        let transport = MockTransport()
        await transport.stub("api/me", status: 401, json: "Unauthorized")
        let backend = AudiobookshelfBackend(baseURL: server, token: "old", transport: transport)
        await #expect(throws: BackendError.api(message: "Audiobookshelf refused the API key. Make a new one in Audiobookshelf › Settings › API Keys.")) {
            try await backend.validateCredentials()
        }
        #expect(AudiobookshelfBackend.error(status: 500, body: Data("Library folder not found".utf8))
            == .api(message: "Audiobookshelf answered 500: Library folder not found"))
        #expect(AudiobookshelfBackend.serverID("calibre:4") == nil)
        await #expect(throws: BackendError.self) { try await backend.delete("abs:li-1") }
    }

    @Test func writesTheMultipartBodyTheUploadPageSends() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "abs-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "CD1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: "CD2"), withIntermediateDirectories: true)
        let one = folder.appending(path: "CD1/01.mp3")
        let two = folder.appending(path: "CD2/01.mp3")
        try Data("first".utf8).write(to: one)
        try Data("second".utf8).write(to: two)

        let body = folder.appending(path: "body")
        let boundary = try AudiobookshelfUpload.writeBody(
            to: body, files: [one, two], title: "Solaris", author: "Stanisław Lem", series: nil,
            libraryID: "lib-books", folderID: "fol-1"
        )
        let text = try String(contentsOf: body, encoding: .utf8)
        #expect(text.hasPrefix("--\(boundary)\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nSolaris\r\n"))
        #expect(text.contains("name=\"author\"\r\n\r\nStanisław Lem\r\n"))
        #expect(!text.contains("name=\"series\""))
        #expect(text.contains("name=\"library\"\r\n\r\nlib-books\r\n"))
        #expect(text.contains("name=\"folder\"\r\n\r\nfol-1\r\n"))
        #expect(text.contains("name=\"0\"; filename=\"CD1 - 01.mp3\"\r\nContent-Type: application/octet-stream\r\n\r\nfirst\r\n"))
        #expect(text.contains("name=\"1\"; filename=\"CD2 - 01.mp3\""))
        #expect(text.hasSuffix("--\(boundary)--\r\n"))
    }

    @Test func keepsPlainNamesWhenTheyDoNotRepeat() {
        let names = AudiobookshelfUpload.uploadNames(for: [
            URL(filePath: "/t/Book/01.mp3"), URL(filePath: "/t/Book/Extras/cover.jpg"),
        ])
        #expect(names == ["01.mp3", "cover.jpg"])
    }
}
