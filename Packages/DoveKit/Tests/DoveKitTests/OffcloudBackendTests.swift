import Foundation
import Testing
@testable import DoveKit

struct OffcloudBackendTests {
    private let validMagnet = "magnet:?xt=urn:btih:1a07d876aaaebe797c21eff39df7436d2f739b7a&dn=Ubuntu"

    private func makeBackend() -> (OffcloudBackend, MockTransport) {
        let transport = MockTransport()
        return (OffcloudBackend(apiKey: "test-key", transport: transport), transport)
    }

    private func jsonBody(_ request: URLRequest) -> [String: String] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: String] ?? [:]
    }

    @Test func addMagnetPostsJSONWithBearerAuthAndNoKeyInQuery() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("/cloud", json: #"{"requestId":"abc123","fileName":"Ubuntu","status":"downloaded"}"#)

        let id = try await backend.add(.magnet(validMagnet))

        #expect(id == "cloud:abc123")
        let sent = try #require(await transport.requests.last)
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(sent.url?.query() == nil)
        #expect(jsonBody(sent)["url"] == validMagnet)
    }

    @Test func invalidMagnetIsRefusedBeforeCallingOffcloud() async {
        let (backend, transport) = makeBackend()
        await #expect(throws: BackendError.api(message: "This magnet has no valid info hash.")) {
            try await backend.add(.magnet("magnet:?xt=urn:btih:zzzz"))
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func base32InfoHashIsValid() {
        #expect(OffcloudMagnet.hasValidInfoHash("magnet:?xt=urn:btih:DIDXQ5VK5K7HSPBB57ZZ35DUNUXXHG32"))
    }

    @Test func nzbLinkIsPostedLikeAnyURLWhenUsenetIsOn() async throws {
        let transport = MockTransport()
        let backend = OffcloudBackend(apiKey: "test-key", usenet: true, transport: transport)
        await transport.stub("/cloud", json: #"{"requestId":"nzb1","fileName":"Some.Movie.2023.nzb","status":"created"}"#)

        #expect(backend.supportedSources.contains(.nzb))
        let id = try await backend.add(.nzbURL(URL(string: "https://indexer.example/getnzb/1.nzb")!))

        #expect(id == "cloud:nzb1")
        let sent = try #require(await transport.requests.last)
        #expect(jsonBody(sent)["url"] == "https://indexer.example/getnzb/1.nzb")
    }

    @Test func nzbFileIsUploadedAsMultipart() async throws {
        let transport = MockTransport()
        let backend = OffcloudBackend(apiKey: "test-key", usenet: true, transport: transport)
        await transport.stub("/cloud", json: #"{"requestId":"nzb2","status":"created"}"#)

        _ = try await backend.add(.nzbFile(data: Data("<nzb/>".utf8), filename: "Some.Movie.2023.nzb"))

        let sent = try #require(await transport.requests.last)
        #expect(sent.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
        let body = String(decoding: sent.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains(#"name="file"; filename="Some.Movie.2023.nzb""#))
        #expect(body.contains("application/x-nzb"))
    }

    @Test func nzbIsRefusedWithUsenetOff() async {
        let (backend, transport) = makeBackend()
        #expect(!backend.supportedSources.contains(.nzb))
        await #expect(throws: BackendError.unsupportedSource(.nzb)) {
            try await backend.add(.nzbURL(URL(string: "https://indexer.example/1.nzb")!))
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func notAvailableBecomesReadableError() async {
        let (backend, transport) = makeBackend()
        await transport.stub("/cloud", json: #"{"not_available":"cloud"}"#)
        await #expect(throws: BackendError.api(message: OffcloudBackend.notAvailableMessage("cloud"))) {
            try await backend.add(.hosterURL(URL(string: "https://hoster.example/f")!))
        }
    }

    @Test func noAuthIsUnauthorized() async {
        let (backend, transport) = makeBackend()
        await transport.stub("account/info", status: 401, json: #"{"error":"NOAUTH"}"#)
        await #expect(throws: BackendError.unauthorized) {
            try await backend.validateCredentials()
        }
    }

    @Test func nonPremiumAccountFailsValidation() async {
        let (backend, transport) = makeBackend()
        await transport.stub("account/info", json: #"{"user_id":"u","email":"e","is_premium":false,"expiration_date":"2026-01-01","can_download":false}"#)
        await #expect(throws: BackendError.api(message: "This Offcloud account is not premium.")) {
            try await backend.validateCredentials()
        }
    }

    @Test func htmlPageIsNotParsedAsSuccess() async {
        let (backend, transport) = makeBackend()
        await transport.stub("cloud/history", html: "<html>Not found</html>")
        await #expect(throws: BackendError.invalidResponse) {
            try await backend.items()
        }
    }

    @Test func historyMapsStatuses() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("cloud/history", body: try Fixture.data("offcloud_history"))

        let items = try await backend.items()

        #expect(items.map(\.status) == [
            .ready, .ready, .downloading(progress: 0.42), .failed(reason: "Not enough seeders"), .ready
        ])
        #expect(items[0].id == "cloud:66f1a2b3c4d5e6f7a8b9c0d1")
        // The hash comes from the magnet, or from the `<hash>.torrent` name Offcloud now stores; hoster links have none.
        #expect(items.map(\.infoHash) == [
            String(repeating: "a", count: 40), nil, String(repeating: "b", count: 40), nil, String(repeating: "c", count: 40)
        ])
    }

    @Test func folderFilesComeFromDetailedExplore() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("cloud/history", body: try Fixture.data("offcloud_history"))
        await transport.stub("cloud/explore/66f1a2b3c4d5e6f7a8b9c0d1", json: """
            {"files":[
              {"id":"1","name":"S02E01.mkv","size":1500000000,"path":"Some.Show.S02/Season 2/Some.Show.S02E01.mkv",
               "url":"https://fr-3.offcloud.com/cloud/download/x/1/Some.Show.S02E01.mkv"},
              {"id":"2","name":"x","size":1400000000,"path":"Some.Show.S02/Some Show S02E02.mkv",
               "url":"https://fr-3.offcloud.com/cloud/download/x/2/Some%20Show%20S02E02.mkv"}
            ]}
            """)

        let item = try await backend.item("cloud:66f1a2b3c4d5e6f7a8b9c0d1")
        // The shared root folder goes; subfolders stay.
        #expect(item.files.map(\.name) == ["Season 2/Some.Show.S02E01.mkv", "Some Show S02E02.mkv"])
        #expect(item.files.map(\.size) == [1_500_000_000, 1_400_000_000])
        let explore = try #require(await transport.requests.last)
        #expect(explore.url?.query() == "format=detailed")

        let request = try await backend.downloadRequest(itemID: item.id, fileID: "1")
        #expect(request.url?.absoluteString == "https://fr-3.offcloud.com/cloud/download/x/2/Some%20Show%20S02E02.mkv")
    }

    @Test func singleFileWithoutServerComesFromCacheDownload() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("cloud/history", body: try Fixture.data("offcloud_history"))
        await transport.stub("cloud/explore/66f1a2b3c4d5e6f7a8b9c0d5", status: 400, json: #"{"error":"Bad archive"}"#)
        await transport.stub("cache/download", json: """
            [{"folder":[],"filename":"Another Movie (2025).mkv","size":4000000000,"url":"https://cdn.offcloud.com/download/m"}]
            """)

        let item = try await backend.item("cloud:66f1a2b3c4d5e6f7a8b9c0d5")

        #expect(item.files == [LibraryFile(id: "0", name: "Another Movie (2025).mkv", size: 4_000_000_000)])
        let sent = try #require(await transport.requests.last)
        let body = try JSONSerialization.jsonObject(with: sent.httpBody ?? Data()) as? [String: String]
        #expect(body?["url"] == "magnet:?xt=urn:btih:\(String(repeating: "c", count: 40))")
    }

    @Test func filesOutsideOneRootKeepTheirPaths() {
        let files = OffcloudBackend.libraryFiles([
            OffcloudFile(url: "https://x/1", path: "A/a.mkv", folder: nil, filename: nil, size: nil),
            OffcloudFile(url: "https://x/2", path: "b.srt", folder: nil, filename: nil, size: nil)
        ])
        #expect(files.map(\.name) == ["A/a.mkv", "b.srt"])
    }

    @Test func singleFileUsesTheServerDownloadURL() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("cloud/history", body: try Fixture.data("offcloud_history"))

        let request = try await backend.downloadRequest(itemID: "cloud:66f1a2b3c4d5e6f7a8b9c0d2", fileID: "0")

        #expect(request.url?.absoluteString == "https://nl-1.offcloud.com/cloud/download/66f1a2b3c4d5e6f7a8b9c0d2/Some%20Movie%20(2024).mkv")
        #expect(await transport.requests.count == 1)
    }

    @Test func deletePostsTheRequestID() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("cloud/remove", json: #"{"success":true}"#)

        try await backend.delete("cloud:abc123")

        let sent = try #require(await transport.requests.last)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path.hasSuffix("/api/cloud/remove") == true)
        let body = try JSONSerialization.jsonObject(with: sent.httpBody ?? Data()) as? [String: [String]]
        #expect(body?["requests"] == ["abc123"])
    }

    @Test func refusedDeleteIsAnError() async {
        let (backend, transport) = makeBackend()
        await transport.stub("cloud/remove", json: #"{"success":false}"#)
        await #expect(throws: BackendError.api(message: "Offcloud did not remove this download.")) {
            try await backend.delete("cloud:abc123")
        }
    }

    @Test func itemRefRoundTrips() {
        #expect(OffcloudItemRef("cloud:abc") == .cloud("abc"))
        #expect(OffcloudItemRef("torrent:abc") == nil)
    }
}
