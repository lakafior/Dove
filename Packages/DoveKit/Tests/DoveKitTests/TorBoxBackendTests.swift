import Foundation
import Testing
@testable import DoveKit

struct TorBoxBackendTests {
    private func makeBackend() -> (TorBoxBackend, MockTransport) {
        let transport = MockTransport()
        return (TorBoxBackend(apiKey: "test-key", transport: transport), transport)
    }

    @Test func itemsMergesTorrentsAndWebDownloadsNewestFirst() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("torrents/mylist", body: try Fixture.data("torbox_torrents_mylist"))
        await transport.stub("webdl/mylist", body: try Fixture.data("torbox_webdl_mylist"))

        let items = try await backend.items()

        #expect(items.map(\.id) == ["webdl:7", "torrent:102", "torrent:101", "torrent:103"])
        let season = try #require(items.first { $0.id == "torrent:101" })
        #expect(season.status == .ready)
        #expect(season.files.map(\.name) == ["Some.Show.S02E01.mkv", "Some.Show.S02E02.mkv"])
        #expect(items.first { $0.id == "torrent:102" }?.status == .downloading(progress: 0.42))
        #expect(items.first { $0.id == "torrent:103" }?.status == .failed(reason: "stalled (no seeds)"))
    }

    @Test func addMagnetPostsMultipartWithBearerAuth() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("torrents/createtorrent", json: #"{"success":true,"data":{"torrent_id":555,"hash":"x"}}"#)

        let id = try await backend.add(.magnet("magnet:?xt=urn:btih:abc"))

        #expect(id == "torrent:555")
        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("name=\"magnet\""))
    }

    @Test func nzbIsRejected() async {
        let (backend, _) = makeBackend()
        await #expect(throws: BackendError.unsupportedSource(.nzb)) {
            try await backend.add(.nzbURL(URL(string: "https://x.example/a.nzb")!))
        }
    }

    @Test func unauthorizedIsMapped() async {
        let (backend, transport) = makeBackend()
        await transport.stub("user/me", status: 401, json: #"{"success":false,"error":"AUTH_ERROR"}"#)
        await #expect(throws: BackendError.unauthorized) {
            try await backend.validateCredentials()
        }
    }

    @Test func apiErrorCarriesDetail() async {
        let (backend, transport) = makeBackend()
        await transport.stub(
            "torrents/createtorrent",
            status: 400,
            json: #"{"success":false,"error":"ACTIVE_LIMIT","detail":"You have reached your active torrent limit."}"#
        )
        await #expect(throws: BackendError.api(message: "You have reached your active torrent limit.")) {
            try await backend.add(.magnet("magnet:?xt=urn:btih:abc"))
        }
    }

    @Test func downloadRequestUsesTokenQueryNotHeader() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("torrents/requestdl", json: #"{"success":true,"data":"https://cdn.example/file.mkv"}"#)

        let request = try await backend.downloadRequest(itemID: "torrent:101", fileID: "0")

        #expect(request.url?.absoluteString == "https://cdn.example/file.mkv")
        let sent = try #require(await transport.requests.last)
        let query = URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "token", value: "test-key")))
        #expect(query.contains(URLQueryItem(name: "torrent_id", value: "101")))
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func addWhenSlotsAreFullReturnsQueuedID() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("torrents/createtorrent", json: #"{"success":true,"data":{"queued_id":9,"hash":"x"}}"#)

        let id = try await backend.add(.magnet("magnet:?xt=urn:btih:abc"))

        #expect(id == "queued:9")
    }

    @Test func deleteWebDownloadSendsWebdlID() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("webdl/controlwebdownload", json: #"{"success":true,"data":null}"#)

        try await backend.delete("webdl:7")

        let request = try #require(await transport.requests.last)
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        #expect(body?["webdl_id"] as? Int == 7)
        #expect(body?["operation"] as? String == "delete")
    }

    @Test func deleteQueuedUsesQueueEndpoint() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("queued/controlqueued", json: #"{"success":true,"data":null}"#)

        try await backend.delete("queued:9")

        let request = try #require(await transport.requests.last)
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        #expect(body?["queued_id"] as? Int == 9)
    }

    @Test func itemRefRoundTrips() {
        #expect(TorBoxItemRef("torrent:12") == .torrent(12))
        #expect(TorBoxItemRef("webdl:3")?.id == "webdl:3")
        #expect(TorBoxItemRef("queued:4") == .queued(4))
        #expect(TorBoxItemRef("garbage") == nil)
    }

    // MARK: - Usenet

    @Test func usenetIsOffByDefault() async {
        let (backend, transport) = makeBackend()
        #expect(!backend.supportedSources.contains(.nzb))
        await #expect(throws: BackendError.unsupportedSource(.nzb)) {
            try await backend.add(.nzbURL(URL(string: "https://indexer.example/get/1")!))
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func usenetAddsListsDownloadsAndDeletes() async throws {
        let transport = MockTransport()
        let backend = TorBoxBackend(apiKey: "test-key", usenet: true, transport: transport)
        #expect(backend.supportedSources.contains(.nzb))
        await transport.stub("usenet/createusenetdownload", json: #"{"success":true,"data":{"usenetdownload_id":"77","hash":"h","auth_id":"a"}}"#)
        await transport.stub("torrents/mylist", json: #"{"success":true,"data":[]}"#)
        await transport.stub("webdl/mylist", json: #"{"success":true,"data":[]}"#)
        await transport.stub("usenet/mylist", json: """
            {"success":true,"data":[{"id":77,"name":"Show.S01E01.1080p","size":100,"download_state":"completed",
            "download_finished":true,"download_present":true,"progress":1,"created_at":"2026-10-12T10:00:00Z",
            "files":[{"id":0,"name":"Show.S01E01.1080p/Show.S01E01.1080p.mkv","short_name":"Show.S01E01.1080p.mkv","size":100}]}]}
            """)
        await transport.stub("usenet/requestdl", json: #"{"success":true,"data":"https://cdn.example/dl/abc"}"#)
        await transport.stub("usenet/controlusenetdownload", json: #"{"success":true,"data":null}"#)

        let id = try await backend.add(.nzbURL(URL(string: "https://indexer.example/get/1")!))
        #expect(id == "usenet:77")
        let create = try #require(await transport.requests.last)
        #expect(String(decoding: create.httpBody ?? Data(), as: UTF8.self).contains("https://indexer.example/get/1"))

        let items = try await backend.items()
        #expect(items.map(\.id) == ["usenet:77"])
        #expect(items[0].status == .ready)

        let request = try await backend.downloadRequest(itemID: "usenet:77", fileID: "0")
        #expect(request.url?.absoluteString == "https://cdn.example/dl/abc")
        let requestdl = try #require(await transport.requests.last?.url)
        let query = URLComponents(url: requestdl, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "usenet_id", value: "77")))
        #expect(query.contains(URLQueryItem(name: "token", value: "test-key")))

        try await backend.delete("usenet:77")
        let delete = try #require(await transport.requests.last)
        let body = try JSONSerialization.jsonObject(with: delete.httpBody ?? Data()) as? [String: Any]
        #expect(body?["usenet_id"] as? Int == 77)
        #expect(body?["operation"] as? String == "delete")
    }
}
