import Foundation
import Testing
@testable import DoveKit

struct DirectDownloadTests {
    private let source = DirectSource(id: "s1", name: "Books", url: URL(string: "https://books.example")!, key: "SECRET")
    private let md5 = "d6e1dc51a50726f00ec438af21952a45"

    @Test func linksCarryTheQuotaAndTheFileName() async throws {
        let transport = MockTransport()
        await transport.stub("/dyn/api/fast_download.json", json: """
        {"download_url":"https://cdn.example/d/~/Andy%20Weir%20--%20Project%20Hail%20Mary.epub","error":null,
         "account_fast_download_info":{"downloads_left":24,"downloads_per_day":25,"downloads_done_today":1,"recently_downloaded_md5s":[]}}
        """)
        let link = try await DirectDownloadClient(source: source, transport: transport).link(md5: md5)

        #expect(link.url.host() == "cdn.example")
        #expect(link.quota == DirectDownloadQuota(left: 24, perDay: 25, doneToday: 1))
        #expect(link.fileName(md5: md5) == "Andy Weir -- Project Hail Mary.epub")

        let request = try #require(await transport.requests.first)
        #expect(request.url?.path() == "/dyn/api/fast_download.json")
        #expect(request.url?.query == "md5=\(md5)&key=SECRET")
    }

    @Test func errorsSayWhat() async throws {
        let transport = MockTransport()
        await transport.stub("/dyn/api/fast_download.json", status: 401, json: #"{"download_url":null,"error":"Invalid secret key"}"#)
        await #expect(throws: BackendError.api(message: "Invalid secret key")) {
            try await DirectDownloadClient(source: source, transport: transport).link(md5: md5)
        }
    }

    @Test func aParkedDomainIsAWrongAddress() async throws {
        let transport = MockTransport()
        await transport.stub("/dyn/api/fast_download.json", status: 404, html: "<html>404 Not Found</html>")
        await #expect(throws: BackendError.api(message: "books.example has no download API. Check the address in Settings.")) {
            try await DirectDownloadClient(source: source, transport: transport).link(md5: md5)
        }
    }

    @Test func validationSpendsNoDownload() async throws {
        let good = MockTransport()
        await good.stub("/dyn/api/fast_download.json", status: 404, json: #"{"download_url":null,"error":"Record not found"}"#)
        try await DirectDownloadClient(source: source, transport: good).validate()
        #expect(await good.requests.first?.url?.query?.contains("md5=00000000000000000000000000000000") == true)

        let bad = MockTransport()
        await bad.stub("/dyn/api/fast_download.json", status: 401, json: #"{"download_url":null,"error":"Invalid secret key"}"#)
        await #expect(throws: BackendError.api(message: "Invalid secret key")) {
            try await DirectDownloadClient(source: source, transport: bad).validate()
        }
    }

    @Test func filePagesAndAddresses() {
        #expect(DirectSource.md5(in: URL(string: "https://mirror.example/md5/D6E1DC51A50726F00EC438AF21952A45")!) == md5)
        #expect(DirectSource.md5(in: URL(string: "https://x.example/md5/123")!) == nil)
        #expect(DirectSource.md5(in: URL(string: "https://x.example/search?q=md5")!) == nil)
        #expect(DirectSource.url(from: "books.example/search?q=x")?.absoluteString == "https://books.example")
        #expect(DirectSource.url(from: "ftp://x") == nil)
        #expect(source.searchURL("andy weir project hail mary").absoluteString
            == "https://books.example/search?q=andy%20weir%20project%20hail%20mary&ext=epub")
        #expect(source.searchURL("dune", extensions: []).absoluteString == "https://books.example/search?q=dune")
    }

    @Test func sitesServeTheirCategories() throws {
        #expect(source.serves(.books) && !source.serves(.software), "books by default")
        var off = DirectSource(name: "X", url: URL(string: "https://x.example")!, key: "K", categories: [.software, .music])
        #expect(off.serves(.software) && off.serves(.music) && !off.serves(.books))
        off.enabled = false
        #expect(!off.serves(.software))

        let saved = Data(#"[{"id":"a","name":"Old","url":"https://old.example","key":"K","api":"fastDownloadJSON","enabled":true}]"#.utf8)
        let decoded = try JSONDecoder().decode([DirectSource].self, from: saved)
        #expect(decoded.first?.categories == [.books], "sites saved before categories serve books")
        let roundTrip = try JSONDecoder().decode(DirectSource.self, from: JSONEncoder().encode(off))
        #expect(roundTrip == off)
    }

    @Test @MainActor func directDownloadsAreRecordedWithTheirSource() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "direct-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = DownloadManager(
            configuration: .ephemeral, directory: directory, store: DownloadStore(directory: directory.appending(path: "store"))
        )
        let ref = DirectDownloadRef(sourceID: "s1", md5: md5)
        let request = URLRequest(url: URL(string: "https://cdn.invalid/file.epub")!)
        let id = try manager.start(request, direct: ref, name: "Book.epub")
        #expect(try manager.start(request, direct: ref, name: "Book.epub") == id, "the same file is not fetched twice")
        let record = try #require(manager.records.first)
        #expect(record.direct == ref && record.backend == nil && record.name == "Book.epub")
        manager.remove(id)
    }
}
