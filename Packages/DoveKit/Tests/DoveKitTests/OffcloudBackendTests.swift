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

        #expect(items.map(\.status) == [.ready, .ready, .queued, .failed(reason: "error")])
        #expect(items[0].id == "cloud:66f1a2b3c4d5e6f7a8b9c0d1")
    }

    @Test func folderFilesComeFromExplore() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("cloud/history", body: try Fixture.data("offcloud_history"))
        await transport.stub("cloud/explore/66f1a2b3c4d5e6f7a8b9c0d1", json: """
            ["https://fr-3.offcloud.com/cloud/download/x/Some.Show.S02E01.mkv?sig=1",
             "https://fr-3.offcloud.com/cloud/download/x/Some%20Show%20S02E02.mkv?sig=2"]
            """)

        let item = try await backend.item("cloud:66f1a2b3c4d5e6f7a8b9c0d1")
        #expect(item.files.map(\.name) == ["Some.Show.S02E01.mkv", "Some Show S02E02.mkv"])

        let request = try await backend.downloadRequest(itemID: item.id, fileID: "1")
        #expect(request.url?.absoluteString == "https://fr-3.offcloud.com/cloud/download/x/Some%20Show%20S02E02.mkv?sig=2")
    }

    @Test func singleFileUsesTheServerDownloadURL() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("cloud/history", body: try Fixture.data("offcloud_history"))

        let request = try await backend.downloadRequest(itemID: "cloud:66f1a2b3c4d5e6f7a8b9c0d2", fileID: "0")

        #expect(request.url?.absoluteString == "https://nl-1.offcloud.com/cloud/download/66f1a2b3c4d5e6f7a8b9c0d2/Some%20Movie%20(2024).mkv")
        #expect(await transport.requests.count == 1)
    }

    @Test func deleteCallsRemove() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("cloud/remove/abc123", json: #"{"success":true}"#)

        try await backend.delete("cloud:abc123")

        #expect(await transport.requests.last?.httpMethod == "GET")
    }

    @Test func itemRefRoundTrips() {
        #expect(OffcloudItemRef("cloud:abc") == .cloud("abc"))
        #expect(OffcloudItemRef("torrent:abc") == nil)
    }
}
