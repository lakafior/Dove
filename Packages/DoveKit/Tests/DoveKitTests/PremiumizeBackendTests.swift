import Foundation
import Testing
@testable import DoveKit

/// Fixtures follow the field names in premiumize.me/api; not yet checked against a live account.
struct PremiumizeBackendTests {
    private func makeBackend(usenet: Bool = true) -> (PremiumizeBackend, MockTransport) {
        let transport = MockTransport()
        return (PremiumizeBackend(apiKey: "test-key", usenet: usenet, transport: transport), transport)
    }

    private func form(_ request: URLRequest) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private func stubCloud(_ transport: MockTransport) async throws {
        await transport.stub("transfer/list", body: try Fixture.data("premiumize_transfer_list"))
        await transport.stub("folder/list", body: try Fixture.data("premiumize_folder_root"))
        await transport.stub("folder/list", queryContains: "id=f-movie", body: try Fixture.data("premiumize_folder_movie"))
        await transport.stub("folder/list", queryContains: "id=f-subs", body: try Fixture.data("premiumize_folder_subs"))
    }

    @Test func addsAMagnetAsATransfer() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("transfer/create", json: #"{"status":"success","id":"t-new","name":"Show","type":"torrent"}"#)

        let id = try await backend.add(.magnet("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"))

        #expect(id == "transfer:t-new")
        let sent = try #require(await transport.requests.last)
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(form(sent)["src"] == "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
        #expect(sent.url?.query() == nil)
    }

    @Test func hosterLinkCarriesItsPassword() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("transfer/create", json: #"{"status":"success","id":"t-h"}"#)
        _ = try await backend.add(.hosterURL(URL(string: "https://1fichier.com/?abc")!, password: "pw"))
        #expect(form(try #require(await transport.requests.last)) == ["src": "https://1fichier.com/?abc", "password": "pw"])
    }

    @Test func torrentAndNZBFilesGoAsMultipartSrc() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("transfer/create", json: #"{"status":"success","id":"t-f"}"#)
        _ = try await backend.add(.nzbFile(data: Data("<nzb/>".utf8), filename: "Show.nzb"))
        let body = String(decoding: try #require(await transport.requests.last?.httpBody), as: UTF8.self)
        #expect(body.contains(#"name="src"; filename="Show.nzb""#))
        #expect(body.contains("application/x-nzb"))
    }

    @Test func nzbsNeedUsenetOn() async {
        let (backend, _) = makeBackend(usenet: false)
        #expect(!backend.supportedSources.contains(.nzb))
        await #expect(throws: BackendError.unsupportedSource(.nzb)) {
            try await backend.add(.nzbURL(URL(string: "https://indexer.example/get/1.nzb")!))
        }
    }

    @Test func libraryListsUnfinishedTransfersAndTheCloudOnce() async throws {
        let (backend, transport) = makeBackend()
        try await stubCloud(transport)

        let items = try await backend.items()

        #expect(items.map(\.id) == ["transfer:t-run", "transfer:t-err", "file:i-single", "folder:f-movie"])
        #expect(items[0].status == .downloading(progress: 0.42))
        #expect(items[0].infoHash == "0123456789abcdef0123456789abcdef01234567")
        #expect(items[1].status == .failed(reason: "Not enough seeders"))
        #expect(items[2].files == [LibraryFile(id: "i-single", name: "single.mkv", size: 734003200)])
        #expect(items[3].status == .ready)
    }

    @Test func folderFilesAreWalkedWithRelativePaths() async throws {
        let (backend, transport) = makeBackend()
        try await stubCloud(transport)

        let item = try await backend.item("folder:f-movie")

        #expect(item.name == "Movie.2024.2160p")
        #expect(item.files == [
            LibraryFile(id: "i-main", name: "Movie.2024.2160p.mkv", size: 20000000000),
            LibraryFile(id: "i-sub", name: "Subs/en.srt", size: 50000),
        ])
    }

    @Test func aFinishedTransferShowsWhatItPutInTheCloud() async throws {
        let (backend, transport) = makeBackend()
        try await stubCloud(transport)
        let item = try await backend.item("transfer:t-done")
        #expect(item.status == .ready)
        #expect(item.files.map(\.id) == ["i-main", "i-sub"])
    }

    @Test func downloadUsesTheFilesLink() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("item/details", json: #"{"status":"success","id":"i-main","name":"m.mkv","size":5,"link":"https://dl.premiumize.me/x/main.mkv"}"#)
        let request = try await backend.downloadRequest(itemID: "folder:f-movie", fileID: "i-main")
        #expect(request.url?.absoluteString == "https://dl.premiumize.me/x/main.mkv")
        #expect(await transport.requests.last?.url?.query()?.contains("id=i-main") == true)
    }

    @Test func deletingAFinishedTransferRemovesItsFolderToo() async throws {
        let (backend, transport) = makeBackend()
        try await stubCloud(transport)
        await transport.stub("folder/delete", json: #"{"status":"success"}"#)
        await transport.stub("transfer/delete", json: #"{"status":"success"}"#)

        try await backend.delete("transfer:t-done")

        let posts = await transport.requests.filter { $0.httpMethod == "POST" }
        #expect(posts.map { $0.url?.lastPathComponent } == ["delete", "delete"])
        #expect(posts.map { $0.url?.path().contains("folder") == true } == [true, false])
        #expect(form(posts[0])["id"] == "f-movie")
        #expect(form(posts[1])["id"] == "t-done")
    }

    @Test func errorsComeInTheBodyWithStatus200() async {
        let (backend, transport) = makeBackend()
        await transport.stub("transfer/list", json: #"{"status":"error","message":"Not logged in.","code":"authentication_failed"}"#)
        await #expect(throws: BackendError.unauthorized) { try await backend.items() }
    }

    @Test func unsupportedSiteIsExplained() async {
        let (backend, transport) = makeBackend()
        await transport.stub("transfer/create", json: #"{"status":"error","message":"unsupported","code":"service_unsupported"}"#)
        await #expect(throws: BackendError.api(message: "Premiumize does not support this site.")) {
            try await backend.add(.hosterURL(URL(string: "https://example.com/f")!))
        }
    }

    @Test func cacheCheckAsksWithMagnetsInOrder() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("cache/check", json: #"{"status":"success","response":[true,false],"transcoded":[false,false],"filename":["a",""],"filesize":["1",""]}"#)
        let hashes = [String(repeating: "a", count: 40), String(repeating: "b", count: 40)]
        #expect(try await backend.cachedHashes(hashes) == [hashes[0]])
        let query = try #require(await transport.requests.last?.url?.query())
        #expect(query.contains("items%5B%5D=magnet") || query.contains("items[]=magnet"))
    }

    @Test func accountReadsPremiumUntil() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("account/info", json: #"{"status":"success","customer_id":"1","premium_until":4102444800,"limit_used":0.1}"#)
        let account = try await backend.account()
        #expect(account.isPremium)
        #expect(account.premiumUntil == Date(timeIntervalSince1970: 4102444800))
    }

    @Test func hostsComeFromDirectDownloadsWithAliases() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("services/list", json: #"{"status":"success","directdl":["1fichier.com","rapidgator.net"],"cache":[],"aliases":{"rapidgator.net":["rg.to"]}}"#)
        let hosts = try await backend.hostList()
        #expect(hosts.verdict(for: URL(string: "https://rg.to/file/1")!) == .supported("rapidgator.net"))
        #expect(hosts.verdict(for: URL(string: "https://mega.nz/file/1")!) == .unsupported)
    }
}
