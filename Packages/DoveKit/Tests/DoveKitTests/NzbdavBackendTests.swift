import Foundation
import Testing
@testable import DoveKit

struct NzbdavBackendTests {
    private let base = URL(string: "https://nzb.example")!

    private func makeBackend() -> (NzbdavBackend, MockTransport) {
        let transport = MockTransport()
        let backend = NzbdavBackend(
            baseURL: base, apiKey: "test-key", webDAVUser: "user", webDAVPassword: "p@ss:word", transport: transport
        )
        return (backend, transport)
    }

    private func form(_ request: URLRequest) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    private func stubLists(_ transport: MockTransport) async throws {
        await transport.stub("/api", bodyContains: nil, queryContains: "mode=queue", body: try Fixture.data("nzbdav_queue"))
        await transport.stub("/api", bodyContains: nil, queryContains: "mode=history", body: try Fixture.data("nzbdav_history"))
    }

    @Test func apiCallsPostOnlyTheKeyInTheBody() async throws {
        let (backend, transport) = makeBackend()
        try await stubLists(transport)
        _ = try await backend.items()

        let api = await transport.requests.filter { $0.url?.path == "/api" }
        #expect(api.count == 2)
        for request in api {
            #expect(request.httpMethod == "POST")
            #expect(form(request) == ["apikey": "test-key"])
            #expect(query(request)["apikey"] == nil, "the key never goes in the URL")
            #expect(query(request)["output"] == "json")
        }
    }

    private func stubContent(_ transport: MockTransport) async throws {
        await transport.stub("/content", body: try Fixture.data("nzbdav_propfind_content", extension: "xml"), contentType: "text/xml")
        await transport.stub("content/Movies", body: try Fixture.data("nzbdav_propfind_category", extension: "xml"), contentType: "text/xml")
    }

    @Test func itemsMergeQueueHistoryAndFoldersWithoutHistory() async throws {
        let (backend, transport) = makeBackend()
        try await stubLists(transport)
        try await stubContent(transport)

        let items = try await backend.items()

        #expect(items.map(\.id) == [
            "nzo:44444444-4444-4444-4444-444444444444",
            "nzo:11111111-1111-1111-1111-111111111111",
            "nzo:22222222-2222-2222-2222-222222222222",
            "nzo:33333333-3333-3333-3333-333333333333",
            "dav:/content/Movies/Orphan-Movie-2020-1080p-GRP",
        ], "the history's folder is not listed twice; the Tv listing failed and is skipped")
        #expect(items[4].status == .ready)
        #expect(items[4].name == "Orphan-Movie-2020-1080p-GRP")
        #expect(items[4].addedAt == Date(timeIntervalSince1970: 1_791_619_200))
        #expect(items[0].status == .downloading(progress: 0.42))
        #expect(items[0].size == Int64(2048 * 1_048_576))
        #expect(items[1].status == .ready)
        #expect(items[1].addedAt == Date(timeIntervalSince1970: 1_791_748_800))
        #expect(items[2].status == .failed(reason: "Article with message-id abc123 not found."))
        #expect(items[3].addedAt == nil, "the Tv listing failed; the item still loads")
        #expect(items[1].nzbBlobID == "11111111-1111-1111-1111-111111111111")
        #expect(items[2].nzbBlobID == "22222222-2222-2222-2222-222222222222")
        #expect(items[4].nzbBlobID == nil, "folders without history have no stored NZB")

        let propfind = try #require(await transport.requests.first { $0.httpMethod == "PROPFIND" })
        #expect(propfind.value(forHTTPHeaderField: "Depth") == "1")
        #expect(propfind.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("user:p@ss:word".utf8).base64EncodedString())
    }

    @Test func itemListsFilesRecursivelyWithWebDAVPathsAsIDs() async throws {
        let (backend, transport) = makeBackend()
        try await stubLists(transport)
        await transport.stub("Some-Show-S01-1080p-WEB-H264-GRP", body: try Fixture.data("nzbdav_propfind_show", extension: "xml"))
        await transport.stub("Extras & More", body: try Fixture.data("nzbdav_propfind_extras", extension: "xml"))

        let item = try await backend.item("nzo:33333333-3333-3333-3333-333333333333")

        #expect(item.files.map(\.name) == ["Some.Show.S01E01.1080p.WEB.mkv", "Extras & More/Behind the Scenes #1.mkv"])
        #expect(item.files.map(\.id) == [
            "/content/Tv/Some-Show-S01-1080p-WEB-H264-GRP/Some.Show.S01E01.1080p.WEB.mkv",
            "/content/Tv/Some-Show-S01-1080p-WEB-H264-GRP/Extras & More/Behind the Scenes #1.mkv",
        ])
        #expect(item.files.first?.size == 2_000_000_000)
        let history = try #require(await transport.requests.first { query($0)["mode"] == "history" })
        #expect(query(history)["nzo_ids"] == "33333333-3333-3333-3333-333333333333")
    }

    @Test func queuedItemHasNoFilesYet() async throws {
        let (backend, transport) = makeBackend()
        try await stubLists(transport)

        let item = try await backend.item("nzo:44444444-4444-4444-4444-444444444444")

        #expect(item.status == .downloading(progress: 0.42))
        #expect(item.files.isEmpty)
    }

    @Test func downloadAndPlaybackURLsEncodeThePathAndCarryTheLogin() async throws {
        let (backend, _) = makeBackend()
        let file = "/content/Tv/Show/Extras & More/Behind the Scenes #1?.mkv"

        let request = try await backend.downloadRequest(itemID: "nzo:x", fileID: file)
        #expect(request.url?.absoluteString == "https://nzb.example/content/Tv/Show/Extras%20&%20More/Behind%20the%20Scenes%20%231%3F.mkv")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("user:p@ss:word".utf8).base64EncodedString())

        let play = try await backend.playbackURL(itemID: "nzo:x", fileID: file)
        #expect(play.user == "user")
        #expect(play.password(percentEncoded: false) == "p@ss:word", "special characters are encoded in the URL")
        #expect(play.path == "/content/Tv/Show/Extras & More/Behind the Scenes #1?.mkv")

        await #expect(throws: BackendError.notFound) {
            try await backend.downloadRequest(itemID: "nzo:x", fileID: "/etc/passwd")
        }
    }

    /// nzbdav reads `name` only from the query; the link's own `&` and `=` must be encoded.
    @Test func addURLSendsTheLinkInTheQuery() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("/api", bodyContains: nil, queryContains: "mode=addurl", json: #"{"status":true,"error":null,"nzo_ids":["55555555-5555-5555-5555-555555555555"]}"#)
        let nzb = URL(string: "https://indexer.example/api?t=get&id=abc&apikey=INDEXER")!

        let id = try await backend.add(.nzbURL(nzb))

        #expect(id == "nzo:55555555-5555-5555-5555-555555555555")
        let sent = try #require(await transport.requests.last)
        #expect(query(sent)["name"] == nzb.absoluteString)
        #expect(sent.url?.query?.contains("t%3Dget%26id%3Dabc") == true)
        #expect(form(sent) == ["apikey": "test-key"])
    }

    @Test func addFileUploadsMultipart() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("/api", bodyContains: nil, queryContains: "mode=addfile", json: #"{"status":true,"nzo_ids":["66666666-6666-6666-6666-666666666666"]}"#)

        let id = try await backend.add(.nzbFile(data: Data("<nzb/>".utf8), filename: "show.nzb"))

        #expect(id == "nzo:66666666-6666-6666-6666-666666666666")
        let sent = try #require(await transport.requests.last)
        #expect(sent.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = String(decoding: sent.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains(#"name="nzbFile"; filename="show.nzb""#))
        #expect(body.contains("test-key"))
        #expect(query(sent)["apikey"] == nil)
    }

    @Test func deleteUsesTheQueueOrTheHistory() async throws {
        let (backend, transport) = makeBackend()
        try await stubLists(transport)
        await transport.stub("/api", bodyContains: nil, queryContains: "name=delete", json: #"{"status":true}"#)

        try await backend.delete("nzo:44444444-4444-4444-4444-444444444444")
        try await backend.delete("nzo:11111111-1111-1111-1111-111111111111")

        let deletes = await transport.requests.filter { query($0)["name"] == "delete" }.map(query)
        #expect(deletes.map { $0["mode"] } == ["queue", "history"])
        #expect(deletes[1]["del_completed_files"] == "1")
        #expect(deletes[1]["value"] == "11111111-1111-1111-1111-111111111111")
    }

    @Test func wrongKeyIsUnauthorizedAndWrongLoginSaysSo() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("/api", status: 401, json: #"{"status":false,"error":"API Key Incorrect"}"#)
        await #expect(throws: BackendError.unauthorized) { try await backend.validateCredentials() }

        let (other, otherTransport) = makeBackend()
        await otherTransport.stub("/api", json: #"{"queue":{"slots":[]},"status":true}"#)
        await otherTransport.stub("/", status: 401, json: "")
        await #expect(throws: BackendError.api(message: "WebDAV refused the user name or password.")) {
            try await other.validateCredentials()
        }
    }

    @Test func apiErrorsAreReadable() async {
        let (backend, transport) = makeBackend()
        await transport.stub("/api", json: #"{"status":false,"error":"Nzb filename could not be determined."}"#)
        await #expect(throws: BackendError.api(message: "Nzb filename could not be determined.")) {
            try await backend.add(.nzbURL(URL(string: "https://indexer.example/x")!))
        }
    }

    @Test func itemRefs() {
        #expect(NzbdavItemRef("nzo:abc") == .job("abc"))
        #expect(NzbdavItemRef("dav:/content/Tv/Show") == .folder("/content/Tv/Show"))
        #expect(NzbdavItemRef("dav:/etc") == nil)
        #expect(NzbdavItemRef("torrent:1") == nil)
        #expect(NzbdavItemRef("nzo:") == nil)
    }

    @Test func folderItemListsItsFiles() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("Some-Show-S01-1080p-WEB-H264-GRP", body: try Fixture.data("nzbdav_propfind_show", extension: "xml"))
        await transport.stub("Extras & More", body: try Fixture.data("nzbdav_propfind_extras", extension: "xml"))

        let item = try await backend.item("dav:/content/Tv/Some-Show-S01-1080p-WEB-H264-GRP")

        #expect(item.name == "Some-Show-S01-1080p-WEB-H264-GRP")
        #expect(item.files.count == 2)
        #expect(item.size == 2_000_000_300)
        #expect(await transport.requests.allSatisfy { $0.httpMethod == "PROPFIND" }, "no API call for a folder")
    }

    @Test func folderIsDeletedOverWebDAV() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("Orphan Movie", status: 204, json: "")

        try await backend.delete("dav:/content/Movies/Orphan Movie")

        let sent = try #require(await transport.requests.last)
        #expect(sent.httpMethod == "DELETE")
        #expect(sent.url?.absoluteString == "https://nzb.example/content/Movies/Orphan%20Movie")
        #expect(sent.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
    }

    @Test func readOnlyNzbdavSaysWhatToChange() async {
        let (backend, transport) = makeBackend()
        await transport.stub("Orphan", status: 403, json: "")
        await #expect(throws: BackendError.api(message: NzbdavBackend.readOnlyMessage)) {
            try await backend.delete("dav:/content/Movies/Orphan")
        }
    }

    @Test func onlyJobFoldersCanBeDeleted() async {
        let (backend, transport) = makeBackend()
        for id in ["dav:/content/Movies", "dav:/content/Movies/A/B", "dav:/content/../nzbs/x"] {
            await #expect(throws: BackendError.notFound) { try await backend.delete(id) }
        }
        #expect(await transport.requests.isEmpty)
    }

    // MARK: - Frontend key

    private func makeBackend(frontendKey: String) -> (NzbdavBackend, MockTransport) {
        let transport = MockTransport()
        let backend = NzbdavBackend(
            baseURL: base, apiKey: "test-key", webDAVUser: "user", webDAVPassword: "p@ss:word",
            frontendKey: frontendKey, transport: transport
        )
        return (backend, transport)
    }

    @Test func storedNZBComesBackWithTheKeyInAHeader() async throws {
        let (backend, transport) = makeBackend(frontendKey: "frontend-key")
        await transport.stub("/api/download-nzb", body: Data("<nzb/>".utf8), contentType: "application/x-nzb")
        let item = LibraryItem(id: "nzo:2", backend: .nzbdav, name: "Some-Movie-2023", status: .failed(reason: "x"), nzbBlobID: "22222222-2222-2222-2222-222222222222")

        #expect(backend.providesNZB(for: item))
        let source = try await backend.nzb(of: item)

        #expect(source == .nzbFile(data: Data("<nzb/>".utf8), filename: "Some-Movie-2023.nzb"))
        let request = try #require(await transport.requests.last)
        #expect(request.url?.absoluteString == "https://nzb.example/api/download-nzb?nzbBlobId=22222222-2222-2222-2222-222222222222")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "frontend-key")
        #expect(request.url?.query?.contains("frontend-key") == false)
    }

    @Test func withoutABlobNothingIsProvided() {
        let (plain, _) = makeBackend()
        #expect(plain.providesNZB(for: LibraryItem(id: "nzo:2", backend: .nzbdav, name: "x", status: .ready, nzbBlobID: "b")))
        #expect(!plain.providesNZB(for: LibraryItem(id: "dav:/content/a/b", backend: .nzbdav, name: "b", status: .ready)))
    }

    /// InfiniDysk takes the SABnzbd key on download-nzb; nzbdav answers 401 and the user learns what to set.
    @Test func withoutTheFrontendKeyTheSABKeyFetchesTheNZB() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("/api/download-nzb", body: Data("<nzb/>".utf8), contentType: "application/x-nzb")
        let item = LibraryItem(id: "nzo:2", backend: .nzbdav, name: "Job", status: .ready, nzbBlobID: "blob")

        _ = try await backend.nzb(of: item)
        #expect(await transport.requests.last?.value(forHTTPHeaderField: "x-api-key") == "test-key")

        let (old, oldTransport) = makeBackend()
        await oldTransport.stub("/api/download-nzb", status: 401, json: #"{"status":false,"error":"API Key Incorrect"}"#)
        await #expect(throws: BackendError.api(message: NzbdavBackend.needsFrontendKeyMessage)) { try await old.nzb(of: item) }
    }

    @Test func retryUsesTheServerOrSaysItCannot() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("/api", queryContains: "mode=retry", json: #"{"status":true,"nzo_id":"99999999-9999-9999-9999-999999999999","nzo_ids":["99999999-9999-9999-9999-999999999999"]}"#)
        let failed = LibraryItem(id: "nzo:22222222-2222-2222-2222-222222222222", backend: .nzbdav, name: "x", status: .failed(reason: "x"), nzbBlobID: "b")

        #expect(try await backend.retry(failed) == "nzo:99999999-9999-9999-9999-999999999999")
        let sent = try #require(await transport.requests.last)
        #expect(query(sent)["value"] == "22222222-2222-2222-2222-222222222222")
        #expect(form(sent)["apikey"] == "test-key")

        let (old, oldTransport) = makeBackend()
        await oldTransport.stub("/api", queryContains: "mode=retry", status: 400, json: #"{"status":false,"error":"Invalid mode"}"#)
        #expect(try await old.retry(failed) == nil)
    }

    /// InfiniDysk: `completed` dates the entry, `storage` names the real folder ("Name (2)" for a second job).
    @Test func historyDateAndFolderComeFromCompletedAndStorage() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("/api", queryContains: "mode=queue", json: #"{"queue":{"slots":[]}}"#)
        await transport.stub("/api", queryContains: "mode=history", json: """
        {"history":{"slots":[{"nzo_id":"11111111-1111-1111-1111-111111111111","name":"Job","category":"Movies","status":"Completed","bytes":10,"completed":1791748800,"storage":"/mnt/nzbdav/completed-symlinks/Movies/Job (2)","nzb_blob_id":"11111111-1111-1111-1111-111111111111"}]}}
        """)
        await transport.stub("Job (2)", status: 207, body: Data(#"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response><d:href>/content/Movies/Job%20(2)/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response><d:response><d:href>/content/Movies/Job%20(2)/a.mkv</d:href><d:propstat><d:prop><d:getcontentlength>5</d:getcontentlength><d:resourcetype/></d:prop></d:propstat></d:response></d:multistatus>"#.utf8), contentType: "application/xml")

        let item = try await backend.item("nzo:11111111-1111-1111-1111-111111111111")

        #expect(item.addedAt == Date(timeIntervalSince1970: 1_791_748_800))
        #expect(item.files.map(\.id) == ["/content/Movies/Job (2)/a.mkv"])
    }

    @Test func contentDispositionNamesTheFile() {
        #expect(NzbdavBackend.filename(fromContentDisposition: #"attachment; filename="A B.nzb"; filename*=UTF-8''A%20B%20%C5%BC.nzb"#) == "A B ż.nzb")
        #expect(NzbdavBackend.filename(fromContentDisposition: "attachment; filename=Plain.nzb") == "Plain.nzb")
        #expect(NzbdavBackend.filename(fromContentDisposition: nil) == nil)
    }

    @Test func frontendKeyIsCheckedWithAnNZBThatCannotExist() async throws {
        let (good, goodTransport) = makeBackend(frontendKey: "right")
        await goodTransport.stub("/api/download-nzb", status: 400, json: #"{"status":false,"error":"NZB not found."}"#)
        try await good.validateFrontendKey()

        let (bad, badTransport) = makeBackend(frontendKey: "wrong")
        await badTransport.stub("/api/download-nzb", status: 401, json: #"{"status":false,"error":"API Key Incorrect"}"#)
        await #expect(throws: BackendError.api(message: NzbdavBackend.frontendKeyMessage)) { try await bad.validateFrontendKey() }
    }

    @Test func playbackUsesSignedViewLinksWithTheKey() async throws {
        let file = "/content/Movies/Some Movie (2023)/Some Movie.mkv"
        let prefix = "https://nzb.example/view/content/Movies/Some%20Movie%20%282023%29/Some%20Movie.mkv?downloadKey="

        // InfiniDysk: HMAC-SHA256, checked with a one-byte request.
        let (backend, transport) = makeBackend(frontendKey: "frontend-key")
        await transport.stub("/Some Movie.mkv", status: 206, body: Data([0]), contentType: "video/x-matroska")
        let url = try await backend.playbackURL(itemID: "nzo:x", fileID: file)
        #expect(url.absoluteString == prefix + "0bd62b0c6c40c9d69f6e97c0fc88ee20c6bf860a5aa3d63764e92985a4e3d998")
        #expect(url.user == nil)
        #expect(await transport.requests.last?.value(forHTTPHeaderField: "Range") == "bytes=0-0")

        // nzbdav refuses the HMAC key: its own SHA-256 one.
        let (old, oldTransport) = makeBackend(frontendKey: "frontend-key")
        await oldTransport.stub("/Some Movie.mkv", status: 401, json: "{}")
        let legacy = try await old.playbackURL(itemID: "nzo:x", fileID: file)
        #expect(legacy.absoluteString == prefix + "aebbfaf48f6aa2b1e47d46f6676a2b1bb0985916b1014ab4cff446425c9b79d5")
        await #expect(throws: BackendError.notFound) { try await backend.playbackURL(itemID: "nzo:x", fileID: "/etc/passwd") }
    }
}
