import Foundation
import Testing
@testable import DoveKit

struct CalibreBackendTests {
    private let home = URL(string: "http://192.168.1.10:8888")!
    private let away = URL(string: "http://100.64.0.5:8888")!

    private let books = """
    {"2544": {"title": "02. Paul z Diuny", "authors": ["Brian Herbert;Kevin J. Anderson"], "formats": ["epub", "mobi"],
      "format_metadata": {"epub": {"size": 672249, "path": "/x"}, "mobi": {"size": 900000}},
      "timestamp": "2025-01-17T12:10:39+00:00", "pubdate": "2012-08-22T22:00:00+00:00",
      "last_modified": "2025-01-17T12:10:43+00:00", "cover": "/get/cover/2544/books",
      "comments": "<p>First line&nbsp;here.</p><p>Second &amp; last.</p>"},
     "7": {"title": "Audio", "authors": ["Unknown"], "formats": ["m4b"], "format_metadata": {"m4b": {"size": 5}},
      "pubdate": "0101-01-01T00:00:00+00:00", "cover": null},
     "8": null}
    """

    private func stubbed() async -> MockTransport {
        let transport = MockTransport()
        await transport.stub("ajax/library-info", json: #"{"library_map": {"books": "books"}, "default_library": "books"}"#)
        await transport.stub("ajax/search/books", json: #"{"book_ids": [2544, 7, 8], "total_num": 3}"#)
        await transport.stub("ajax/books/books", json: books)
        return transport
    }

    @Test func listsBooksWithCalibresOwnMetadata() async throws {
        let transport = await stubbed()
        let items = try await CalibreBackend(addresses: [home], transport: transport).items()

        #expect(items.map(\.id) == ["calibre:2544", "calibre:7"])
        let book = items[0]
        #expect(book.backend == .calibre)
        #expect(book.name == "Brian Herbert - 02. Paul z Diuny")
        #expect(book.files.map(\.id) == ["epub", "mobi"])
        #expect(book.files[0].name == "Brian Herbert - 02. Paul z Diuny.epub")
        #expect(book.size == 1_572_249)
        #expect(book.kindHint == .books)
        #expect(book.book?.authors == ["Brian Herbert", "Kevin J. Anderson"])
        #expect(book.book?.year == 2012)
        #expect(book.book?.cover?.absoluteString == "calibre://cover/books/2544?v=2025-01-17T12:10:43+00:00")
        #expect(book.book?.description == "First line here.\nSecond & last.")
        #expect(book.addedAt != nil)

        let audio = items[1]
        #expect(audio.kindHint == .audiobooks)
        #expect(audio.name == "Audio")
        #expect(audio.book?.year == nil)
        #expect(audio.book?.cover == nil)

        let search = try #require(await transport.requests.first { $0.url!.path.hasSuffix("ajax/search/books") })
        #expect(search.url!.query!.contains("sort=timestamp"))
        #expect(search.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func sendsBasicAuthAndExplainsARefusedLogin() async throws {
        let transport = MockTransport()
        await transport.stub("ajax/library-info", status: 401, json: "{}")
        let backend = CalibreBackend(addresses: [home], user: "mar", password: "secret", transport: transport)

        await #expect(throws: BackendError.api(message: "Calibre refused the login. Check the user and password, and that the server's authentication type is basic.")) {
            try await backend.validateCredentials()
        }
        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("mar:secret".utf8).base64EncodedString())
    }

    @Test func fallsBackToTheAwayAddressAndKeepsUsingIt() async throws {
        let transport = UnreachableHost(home.host()!, inner: await stubbed())
        let backend = CalibreBackend(addresses: [home, away], libraryID: "books", transport: transport)

        _ = try await backend.items()
        #expect(await transport.hosts.prefix(2) == [home.host()!, away.host()!])

        let download = try await backend.downloadRequest(itemID: "calibre:2544", fileID: "epub")
        #expect(download.url?.absoluteString == "http://100.64.0.5:8888/get/epub/2544/books")
        let cover = try await backend.coverRequest(for: URL(string: "calibre://cover/books/2544?v=1")!)
        #expect(cover.url?.absoluteString == "http://100.64.0.5:8888/get/thumb/2544/books?sz=400x600")
    }

    @Test func noAddressAnswers() async {
        let transport = UnreachableHost(home.host()!, inner: MockTransport())
        let backend = CalibreBackend(addresses: [home], libraryID: "books", transport: transport)
        await #expect(throws: BackendError.self) { try await backend.items() }
    }

    @Test func imageCacheAsksTheResolverForItsScheme() async throws {
        let transport = MockTransport()
        await transport.stub("get/thumb/2544/books", body: Data([1, 2, 3]), contentType: "image/jpeg")
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cache = ImageCache(directory: directory, transport: transport)
        let backend = CalibreBackend(addresses: [home], user: "mar", password: "x", transport: transport)
        await cache.setResolver(for: CalibreBackend.coverScheme) { try await backend.coverRequest(for: $0) }

        let data = try await cache.data(for: URL(string: "calibre://cover/books/2544?v=1")!)
        #expect(data == Data([1, 2, 3]))
        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
        try? FileManager.default.removeItem(at: directory)
    }
    @Test func addsAFileAndReportsDuplicates() async throws {
        let transport = MockTransport()
        await transport.stub("ajax/library-info", json: #"{"default_library": "books"}"#)
        await transport.stub("Klara.epub/books", json: #"{"title": "Klara", "authors": ["Kazuo Ishiguro"], "duplicates": [{"title": "Klara i słońce", "authors": ["Kazuo Ishiguro"]}]}"#)
        await transport.stub("Klara.epub/books", json: #"{"title": "Klara", "authors": ["Kazuo Ishiguro"], "book_id": 2851}"#)
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).epub")
        try Data("EPUB".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let backend = CalibreBackend(addresses: [home], user: "mar", password: "x", transport: transport)

        let first = try await backend.addBook(file: file, fileName: "Klara.epub")
        #expect(first == .init(bookID: nil, duplicates: ["Klara i słońce — Kazuo Ishiguro"]))
        let second = try await backend.addBook(file: file, fileName: "Klara.epub", allowDuplicate: true)
        #expect(second.bookID == 2851)

        let uploads = await transport.requests.filter { $0.url!.path.contains("cdb/add-book") }
        #expect(uploads.count == 2)
        #expect(uploads[0].httpMethod == "POST")
        #expect(uploads[0].httpBody == Data("EPUB".utf8))
        #expect(uploads[0].url!.path.contains("/n/Klara.epub/books"))
        #expect(uploads[1].url!.path.contains("/y/Klara.epub/books"))
        #expect(uploads[0].value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
    }

    @Test func setsTheBooksMetadataAndCover() async throws {
        let transport = MockTransport()
        await transport.stub("cdb/set-fields/2851/books", json: #"{"2851": {}}"#)
        let backend = CalibreBackend(addresses: [home], libraryID: "books", transport: transport)
        let book = BookSummary(id: "ol:1", title: "Klara i słońce", authors: ["Kazuo Ishiguro"], description: "Line <one> & two.\n\nNext.")

        try await backend.setMetadata(bookID: 2851, book: book, cover: Data([0xFF, 0xD8, 0xFF, 0x01]))

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let changes = try #require(json["changes"] as? [String: Any])
        #expect(changes["title"] as? String == "Klara i słońce")
        #expect(changes["authors"] as? [String] == ["Kazuo Ishiguro"])
        #expect(changes["comments"] as? String == "<p>Line &lt;one&gt; &amp; two.</p><p>Next.</p>")
        #expect((changes["cover"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
        #expect(json["loaded_book_ids"] as? [Int] == [2851])
    }

    @Test func skipsCoversCalibreCannotTakeAndExplainsReadOnly() async throws {
        let transport = MockTransport()
        await transport.stub("cdb/set-fields/1/books", status: 403, json: "{}")
        let backend = CalibreBackend(addresses: [home], libraryID: "books", transport: transport)
        await #expect(throws: BackendError.self) {
            try await backend.setMetadata(bookID: 1, book: BookSummary(id: "x", title: "T"), cover: Data("RIFF....WEBP".utf8))
        }
        let request = try #require(await transport.requests.first)
        let json = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect((json["changes"] as? [String: Any])?["cover"] == nil)
    }
}

/// Fails every request to one host as if it were out of reach, and passes the rest on.
private actor UnreachableHost: HTTPTransport {
    let host: String
    let inner: any HTTPTransport
    private(set) var hosts: [String] = []

    init(_ host: String, inner: any HTTPTransport) {
        self.host = host
        self.inner = inner
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let requestHost = request.url?.host() ?? ""
        hosts.append(requestHost)
        if requestHost == host { throw URLError(.timedOut) }
        return try await inner.send(request)
    }
}
