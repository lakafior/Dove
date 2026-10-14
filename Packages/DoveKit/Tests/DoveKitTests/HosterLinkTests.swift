import Foundation
import Testing
@testable import DoveKit

/// Hoster links on every service: passwords, folders, and routing by the services' host lists.
struct HosterLinkTests {
    private let link = URL(string: "https://1fichier.com/?abc123")!

    private func form(_ request: URLRequest) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private func json(_ request: URLRequest) -> [String: String] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]) ?? [:]
    }

    private func text(_ request: URLRequest) -> String {
        String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    }

    // MARK: Passwords

    @Test func realDebridSendsThePassword() async throws {
        let transport = MockTransport()
        await transport.stub("unrestrict/link", json: #"{"id":"D1","filename":"f.mkv","download":"https://dl.example/f.mkv"}"#)
        _ = try await RealDebridBackend(apiKey: "k", transport: transport).add(.hosterURL(link, password: "s3cret"))
        let sent = try #require(await transport.requests.last)
        #expect(form(sent)["password"] == "s3cret")
        #expect(form(sent)["link"] == link.absoluteString)
    }

    @Test func noPasswordNoField() async throws {
        let transport = MockTransport()
        await transport.stub("unrestrict/link", json: #"{"id":"D1","filename":"f.mkv","download":"https://dl.example/f.mkv"}"#)
        _ = try await RealDebridBackend(apiKey: "k", transport: transport).add(.hosterURL(link))
        #expect(form(try #require(await transport.requests.last))["password"] == nil)
    }

    @Test func torBoxCreatesAWebDownloadWithThePassword() async throws {
        let transport = MockTransport()
        await transport.stub("webdl/createwebdownload", json: #"{"success":true,"data":{"webdownload_id":42,"hash":"h"}}"#)

        let id = try await TorBoxBackend(apiKey: "k", transport: transport).add(.hosterURL(link, password: "s3cret"))

        #expect(id == "webdl:42")
        let sent = try #require(await transport.requests.last)
        #expect(sent.httpMethod == "POST")
        #expect(text(sent).contains(#"name="link""#))
        #expect(text(sent).contains(link.absoluteString))
        #expect(text(sent).contains(#"name="password""#))
        #expect(text(sent).contains("s3cret"))
    }

    @Test func torBoxQueuesWhenSlotsAreFull() async throws {
        let transport = MockTransport()
        await transport.stub("webdl/createwebdownload", json: #"{"success":true,"data":{"queued_id":7}}"#)
        #expect(try await TorBoxBackend(apiKey: "k", transport: transport).add(.hosterURL(link)) == "queued:7")
    }

    @Test func torBoxErrorKeepsItsDetail() async throws {
        let transport = MockTransport()
        await transport.stub("webdl/createwebdownload", status: 400, json: #"{"success":false,"error":"UNSUPPORTED_SITE","detail":"This site is not supported."}"#)
        await #expect(throws: BackendError.api(message: "This site is not supported.")) {
            try await TorBoxBackend(apiKey: "k", transport: transport).add(.hosterURL(link))
        }
    }

    @Test func debridLinkSendsThePassword() async throws {
        let transport = MockTransport()
        await transport.stub("/downloader/add", json: #"{"success":true,"value":{"id":"ab","name":"f"}}"#)
        _ = try await DebridLinkBackend(apiKey: "k", transport: transport).add(.hosterURL(link, password: "s3cret"))
        #expect(json(try #require(await transport.requests.last)) == ["url": link.absoluteString, "password": "s3cret"])
    }

    @Test func offcloudRefusesPasswords() async {
        let backend = OffcloudBackend(apiKey: "k", transport: MockTransport())
        await #expect(throws: BackendError.api(message: "Offcloud cannot open password-protected links.")) {
            try await backend.add(.hosterURL(link, password: "s3cret"))
        }
    }

    // MARK: Preview

    @Test func realDebridChecksALinkWithoutAddingIt() async throws {
        let transport = MockTransport()
        await transport.stub("unrestrict/check", json: #"{"host":"1fichier.com","link":"https://1fichier.com/?abc123","filename":"Movie.mkv","filesize":123456,"supported":1}"#)
        let info = try await RealDebridBackend(apiKey: "k", transport: transport).check(link, password: "pw")
        #expect(info == HosterLinkInfo(filename: "Movie.mkv", size: 123456, host: "1fichier.com", available: true))
        #expect(form(try #require(await transport.requests.last))["password"] == "pw")
    }

    @Test func aGoneFileIsUnavailable() async throws {
        let transport = MockTransport()
        await transport.stub("unrestrict/check", status: 503, json: #"{"error":"unavailable_file","error_code":24}"#)
        let info = try await RealDebridBackend(apiKey: "k", transport: transport).check(link, password: nil)
        #expect(!info.available)
    }

    // MARK: Folders

    @Test func debridLinkFolderAddsEveryFile() async throws {
        let transport = MockTransport()
        await transport.stub("/downloader/add", json: #"{"success":true,"value":[{"id":"l1","name":"a"},{"id":"l2","name":"b"}]}"#)
        let ids = try await DebridLinkBackend(apiKey: "k", transport: transport)
            .addAll(.hosterURL(link), category: nil, privateTracker: false)
        #expect(ids == ["link:l1", "link:l2"])
    }

    @Test func realDebridFallsBackToTheFolderEndpoint() async throws {
        let transport = MockTransport()
        let folder = URL(string: "https://hoster.example/folder/9")!
        await transport.stub("unrestrict/link", bodyContains: "folder%2F9", status: 503, json: #"{"error":"hoster_unsupported","error_code":16}"#)
        await transport.stub("unrestrict/folder", json: #"["https://hoster.example/file/1","https://hoster.example/file/2"]"#)
        await transport.stub("unrestrict/link", bodyContains: "file%2F1", json: #"{"id":"A","filename":"1.mkv","download":"https://dl.example/1"}"#)
        await transport.stub("unrestrict/link", bodyContains: "file%2F2", json: #"{"id":"B","filename":"2.mkv","download":"https://dl.example/2"}"#)

        let ids = try await RealDebridBackend(apiKey: "k", transport: transport)
            .addAll(.hosterURL(folder), category: nil, privateTracker: false)

        #expect(ids == ["download:A", "download:B"])
    }

    @Test func realDebridKeepsTheOriginalErrorWhenItIsNotAFolder() async {
        let transport = MockTransport()
        await transport.stub("unrestrict/link", status: 503, json: #"{"error":"hoster_unsupported","error_code":16}"#)
        await transport.stub("unrestrict/folder", json: "[]")
        await #expect(throws: BackendError.api(message: "Real-Debrid does not support this hoster.")) {
            try await RealDebridBackend(apiKey: "k", transport: transport)
                .addAll(.hosterURL(link), category: nil, privateTracker: false)
        }
    }

    @Test func routerReportsEveryItemOfAFolder() async throws {
        let transport = MockTransport()
        await transport.stub("/downloader/add", json: #"{"success":true,"value":[{"id":"l1","name":"a"},{"id":"l2","name":"b"}]}"#)
        let router = BackendRouter(backends: [DebridLinkBackend(apiKey: "k", transport: transport)])
        let result = try await router.add(.hosterURL(link))
        #expect(result.itemIDs == ["link:l1", "link:l2"])
        #expect(result.itemID == "link:l1")
    }

    // MARK: Routing by host list

    private func router(_ lists: [BackendID: HostList]) -> BackendRouter {
        BackendRouter(
            backends: [
                RealDebridBackend(apiKey: "k", transport: MockTransport()),
                TorBoxBackend(apiKey: "k", transport: MockTransport()),
                OffcloudBackend(apiKey: "k", transport: MockTransport()),
            ],
            order: [.realDebrid, .torBox, .offcloud],
            hostLists: lists
        )
    }

    @Test func automaticSkipsServicesThatDoNotUnlockTheSite() {
        let router = router([
            .realDebrid: HostList(hosts: [.init(name: "Mega", domains: ["mega.nz"])]),
            .torBox: HostList(hosts: [.init(name: "1Fichier", domains: ["1fichier.com"], online: true)]),
        ])
        // Real-Debrid's list lacks 1fichier; Offcloud has no list, so it stays as a last resort.
        #expect(router.candidates(for: .hosterURL(link)).map(\.id) == [.torBox, .offcloud])
        #expect(router.compatible(with: .hosterURL(link)).map(\.id) == [.realDebrid, .torBox, .offcloud])
        #expect(router.verdict(for: .hosterURL(link), on: .realDebrid) == .unsupported)
        #expect(router.verdict(for: .hosterURL(link), on: .offcloud) == .unknown)
    }

    @Test func downHostersAreSkipped() {
        let router = router([.torBox: HostList(hosts: [.init(name: "1Fichier", domains: ["1fichier.com"], online: false)])])
        #expect(router.candidates(for: .hosterURL(link)).map(\.id) == [.realDebrid, .offcloud])
    }

    @Test func torrentsIgnoreHostLists() {
        let router = router([.realDebrid: HostList(hosts: [])])
        let magnet = Source.magnet("magnet:?xt=urn:btih:" + String(repeating: "a", count: 40))
        #expect(router.candidates(for: magnet).map(\.id) == [.realDebrid, .torBox, .offcloud])
    }

    @Test func noServiceUnlocksTheSite() async {
        var router = BackendRouter(
            backends: [RealDebridBackend(apiKey: "k", transport: MockTransport())],
            hostLists: [.realDebrid: HostList(hosts: [])]
        )
        router.order = [.realDebrid]
        await #expect(throws: BackendError.api(message: "None of your services unlocks 1fichier.com.")) {
            try await router.add(.hosterURL(link))
        }
    }
}
