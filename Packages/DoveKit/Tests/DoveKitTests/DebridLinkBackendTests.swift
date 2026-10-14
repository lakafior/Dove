import Foundation
import Testing
@testable import DoveKit

struct DebridLinkBackendTests {
    private let magnet = "magnet:?xt=urn:btih:1a07d876aaaebe797c21eff39df7436d2f739b7a&dn=Ubuntu"

    private func makeBackend() -> (DebridLinkBackend, MockTransport) {
        let transport = MockTransport()
        return (DebridLinkBackend(apiKey: "test-key", transport: transport), transport)
    }

    private func jsonBody(_ request: URLRequest) -> [String: String] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: String] ?? [:]
    }

    private static let added = #"{"success":true,"value":{"id":"2115ca3cf4356d24510","name":"Ubuntu","status":1,"downloadPercent":0,"files":[]}}"#

    @Test func seedsSoPrivateTorrentsAreAccepted() {
        let (backend, _) = makeBackend()
        #expect(backend.takesPrivateTorrents)
        #expect(backend.supports(.torrentFile(data: TorrentFixture.privateTorrent, filename: "a.torrent")))
        #expect(!backend.supports(.nzbURL(URL(string: "https://x.example/a.nzb")!)))
    }

    @Test func addMagnetPostsJSONWithBearerAuth() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("/seedbox/add", json: Self.added)

        let id = try await backend.add(.magnet(magnet))

        #expect(id == "torrent:2115ca3cf4356d24510")
        let sent = try #require(await transport.requests.last)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == "https://debrid-link.com/api/v2/seedbox/add")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(jsonBody(sent)["url"] == magnet)
    }

    @Test func torrentFileIsUploadedAsMultipart() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("/seedbox/add", json: Self.added)

        _ = try await backend.add(.torrentFile(data: TorrentFixture.privateTorrent, filename: "Some.Movie.torrent"))

        let sent = try #require(await transport.requests.last)
        #expect(sent.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
        let body = String(decoding: sent.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains(#"name="file"; filename="Some.Movie.torrent""#))
        #expect(body.contains("application/x-bittorrent"))
    }

    @Test func hosterLinkGoesToTheDownloader() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("/downloader/add", json: #"{"success":true,"value":{"id":"ab03","name":"f.rar","url":"https://host.example/file/1","downloadUrl":"https://dl6.debrid.link/dl/x","expired":false}}"#)

        let id = try await backend.add(.hosterURL(URL(string: "https://host.example/file/1")!))

        #expect(id == "link:ab03")
        #expect(jsonBody(try #require(await transport.requests.last))["url"] == "https://host.example/file/1")
    }

    @Test func folderLinkAnswersWithAList() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("/downloader/add", json: #"{"success":true,"value":[{"id":"l1","name":"a"},{"id":"l2","name":"b"}]}"#)
        #expect(try await backend.add(.hosterURL(URL(string: "https://host.example/folder/1")!)) == "link:l1")
    }

    @Test func itemsMergeSeedboxAndDownloader() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("/seedbox/list", body: try Fixture.data("debridlink_seedbox_list"))
        await transport.stub("/downloader/list", body: try Fixture.data("debridlink_downloader_list"))

        let items = try await backend.items()

        #expect(items.map(\.id) == ["torrent:6acfd64d5877e", "torrent:2115ca3cf4356d24510", "link:ab034778198a045c1ed80be271cdd029b76874f6fc"])
        let movie = try #require(items.first { $0.id == "torrent:2115ca3cf4356d24510" })
        #expect(movie.backend == .debridLink)
        #expect(movie.status == .ready, "seeding with every file there")
        #expect(movie.infoHash == "36a64b53dcd23d32cf743ae87282b69c7dceb4b0")
        #expect(movie.files.map(\.id) == ["2115ca3cf4356d24510-1"])
        #expect(movie.addedAt == Date(timeIntervalSince1970: 1792005709))
        #expect(movie.seeding == LibraryItem.Seeding(ratio: 1.42, isActive: true, uploadSpeed: 0, peers: 0))

        let show = try #require(items.first { $0.id == "torrent:6acfd64d5877e" })
        #expect(show.status == .downloading(progress: 0.425))
        #expect(show.files.isEmpty, "the ZIP stand-in is not a file of the torrent")
        #expect(show.seeding?.isActive == false, "still downloading")

        let link = try #require(items.last)
        #expect(link.status == .ready)
        #expect(link.files.map(\.id) == ["ab034778198a045c1ed80be271cdd029b76874f6fc"])
        #expect(link.seeding == nil, "hoster links do not seed")

        let listRequest = try #require(await transport.requests.first { $0.url?.path().hasSuffix("/seedbox/list") == true })
        #expect(listRequest.url?.query()?.contains("perPage=100") == true)
    }

    @Test func listsFollowPagination() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("/seedbox/list", queryContains: "page=0", json: #"{"success":true,"value":[{"id":"a","status":100,"downloadPercent":100}],"pagination":{"next":1}}"#)
        await transport.stub("/seedbox/list", queryContains: "page=1", json: #"{"success":true,"value":[{"id":"b","status":100,"downloadPercent":100}],"pagination":{"next":-1}}"#)
        await transport.stub("/downloader/list", json: #"{"success":true,"value":[],"pagination":{"next":-1}}"#)

        let ids = Set(try await backend.items().map(\.id))
        #expect(ids == ["torrent:a", "torrent:b"])
    }

    @Test func singleItemAsksByIDForTheRealFiles() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("/seedbox/list", queryContains: "ids=6acf", json: #"{"success":true,"value":[{"id":"6acf","name":"Show","status":4,"downloadPercent":50,"isZip":false,"files":[{"id":"6acf-1","name":"E01.mkv","size":10,"downloadPercent":100,"downloadUrl":"https://seed1.debrid.link/dl/1"},{"id":"6acf-2","name":"E02.mkv","size":10,"downloadPercent":0,"downloadUrl":""}]}]}"#)

        let item = try await backend.item("torrent:6acf")
        #expect(item.files.map(\.name) == ["E01.mkv", "E02.mkv"])

        let ready = try await backend.downloadRequest(itemID: "torrent:6acf", fileID: "6acf-1")
        #expect(ready.url?.absoluteString == "https://seed1.debrid.link/dl/1")
        #expect(ready.value(forHTTPHeaderField: "Authorization") == nil, "the link works on its own (Infuse)")

        await #expect(throws: BackendError.api(message: "This file is still downloading on Debrid-Link.")) {
            try await backend.downloadRequest(itemID: "torrent:6acf", fileID: "6acf-2")
        }
    }

    @Test func expiredLinkIsGeneratedAgain() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("/downloader/list", json: #"{"success":true,"value":[{"id":"l1","url":"https://host.example/file/1","downloadUrl":"https://dl1.debrid.link/old","expired":true}]}"#)
        await transport.stub("/downloader/add", json: #"{"success":true,"value":{"id":"l2","downloadUrl":"https://dl1.debrid.link/new"}}"#)

        let request = try await backend.downloadRequest(itemID: "link:l1", fileID: "l1")
        #expect(request.url?.absoluteString == "https://dl1.debrid.link/new")
    }

    @Test func deleteUsesTheRemovePath() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("/remove", json: #"{"success":true,"value":["abc"]}"#)

        try await backend.delete("torrent:abc")
        try await backend.delete("link:def")

        let paths = await transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" }
        #expect(paths == ["DELETE /api/v2/seedbox/abc/remove", "DELETE /api/v2/downloader/def/remove"])
    }

    @Test func errorCodesBecomeReadableErrors() async {
        let (backend, transport) = makeBackend()
        await transport.stub("/account/infos", status: 401, json: #"{"success":false,"error":"badToken"}"#)
        await #expect(throws: BackendError.unauthorized) { try await backend.validateCredentials() }

        await transport.stub("/seedbox/add", status: 400, json: #"{"success":false,"error":"maxTransfer"}"#)
        await #expect(throws: BackendError.api(message: "Debrid-Link: too many torrents downloading at once. Try again when one finishes.")) {
            try await backend.add(.magnet(magnet))
        }

        #expect(DebridLinkBackend.error(for: "floodDetected") == .rateLimited)
        #expect(DebridLinkBackend.error(for: "somethingNew") == .api(message: "Debrid-Link: somethingNew"))
    }

    @Test func accountReportsPremiumTime() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("/account/infos", json: #"{"success":true,"value":{"username":"Amy","accountType":1,"premiumLeft":864000}}"#)

        let account = try await backend.account()
        #expect(account.isPremium)
        #expect(account.daysLeft() == 9 || account.daysLeft() == 10)

        let (lifetimeBackend, lifetimeTransport) = makeBackend()
        await lifetimeTransport.stub("/account/infos", json: #"{"success":true,"value":{"accountType":2,"premiumLeft":0}}"#)
        let lifetime = try await lifetimeBackend.account()
        #expect(lifetime.isPremium && lifetime.premiumUntil == nil && lifetime.plan == "Lifetime")
    }
}
