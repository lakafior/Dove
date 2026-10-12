import Foundation
import Testing
@testable import DoveKit

struct RealDebridBackendTests {
    private func makeBackend() -> (RealDebridBackend, MockTransport) {
        let transport = MockTransport()
        let backend = RealDebridBackend(apiKey: "test-key", transport: transport, selectionInterval: .zero)
        return (backend, transport)
    }

    private func form(_ request: URLRequest) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func itemsMergesTorrentsAndDownloadsNewestFirst() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("/torrents", body: try Fixture.data("realdebrid_torrents"))
        await transport.stub("/downloads", body: try Fixture.data("realdebrid_downloads"))

        let items = try await backend.items()

        #expect(items.map(\.id) == ["torrent:EFGH5678", "download:DL777", "torrent:ABCD1234", "torrent:IJKL9012"])
        #expect(items[0].status == .downloading(progress: 0.375))
        #expect(items[2].status == .ready)
        #expect(items[3].status == .failed(reason: "magnet error"))
        #expect(items[1].files.map(\.name) == ["archive.part1.rar"])
        let sent = try #require(await transport.requests.first)
        let query = URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "limit", value: "1000")))
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    @Test func emptyPageWith204IsAnEmptyList() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("/torrents", status: 204, json: "")
        await transport.stub("/downloads", status: 204, json: "")

        #expect(try await backend.items().isEmpty)
    }

    @Test func itemDetailListsSelectedFilesOnly() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("torrents/info/ABCD1234", body: try Fixture.data("realdebrid_torrent_info"))

        let item = try await backend.item("torrent:ABCD1234")

        #expect(item.files.map(\.id) == ["1", "3"])
        #expect(item.files.map(\.name) == ["Some.Show.S02E01.mkv", "Some.Show.S02E02.mkv"])
    }

    @Test func addMagnetWaitsForConversionThenSelectsVideoFiles() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("torrents/addMagnet", status: 201, json: #"{"id":"NEW1","uri":"https://x"}"#)
        await transport.stub("torrents/info/NEW1", json: #"{"id":"NEW1","status":"magnet_conversion","files":[]}"#)
        await transport.stub("torrents/info/NEW1", json: """
            {"id":"NEW1","status":"waiting_files_selection","files":[
              {"id":1,"path":"/Show/Show.S01E01.mkv","bytes":10,"selected":0},
              {"id":2,"path":"/Show/Sample/show.sample.mkv","bytes":1,"selected":0},
              {"id":3,"path":"/Show/Show.S01E02.mkv","bytes":10,"selected":0},
              {"id":4,"path":"/Show/readme.txt","bytes":1,"selected":0}
            ]}
            """)
        await transport.stub("torrents/selectFiles/NEW1", status: 204, json: "")

        let id = try await backend.add(.magnet("magnet:?xt=urn:btih:abc&dn=A+B"))

        #expect(id == "torrent:NEW1")
        let requests = await transport.requests
        let add = try #require(requests.first)
        #expect(add.httpMethod == "POST")
        #expect(add.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(form(add)["magnet"] == "magnet:?xt=urn:btih:abc&dn=A+B")
        let select = try #require(requests.last)
        #expect(select.url?.path.hasSuffix("torrents/selectFiles/NEW1") == true)
        #expect(form(select)["files"] == "1,3")
    }

    @Test func addTorrentFilePutsRawBody() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("torrents/addTorrent", status: 201, json: #"{"id":"T2","uri":"https://x"}"#)
        await transport.stub("torrents/info/T2", json: #"{"id":"T2","status":"downloaded"}"#)

        let id = try await backend.add(.torrentFile(data: Data([1, 2, 3]), filename: "a.torrent"))

        #expect(id == "torrent:T2")
        let put = try #require(await transport.requests.first)
        #expect(put.httpMethod == "PUT")
        #expect(put.httpBody == Data([1, 2, 3]))
    }

    @Test func hosterLinkIsUnrestricted() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("unrestrict/link", json: #"{"id":"DL9","filename":"f.mkv","filesize":5,"download":"https://dl.example/f.mkv"}"#)

        let id = try await backend.add(.hosterURL(URL(string: "https://hoster.example/file/abc")!))

        #expect(id == "download:DL9")
        let sent = try #require(await transport.requests.last)
        #expect(form(sent)["link"] == "https://hoster.example/file/abc")
    }

    @Test func downloadRequestUnrestrictsTheLinkOfTheSelectedFile() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("torrents/info/ABCD1234", body: try Fixture.data("realdebrid_torrent_info"))
        await transport.stub("unrestrict/link", json: #"{"id":"U","filename":"e02.mkv","download":"https://dl.example/e02.mkv"}"#)

        let request = try await backend.downloadRequest(itemID: "torrent:ABCD1234", fileID: "3")

        #expect(request.url?.absoluteString == "https://dl.example/e02.mkv")
        let sent = try #require(await transport.requests.last)
        #expect(form(sent)["link"] == "https://real-debrid.com/d/LINK2")
    }

    @Test func deleteUsesTheRightList() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("downloads/delete/DL777", status: 204, json: "")

        try await backend.delete("download:DL777")

        let sent = try #require(await transport.requests.last)
        #expect(sent.httpMethod == "DELETE")
    }

    @Test func badTokenIsUnauthorized() async {
        let (backend, transport) = makeBackend()
        await transport.stub("/user", status: 401, json: #"{"error":"bad_token","error_code":8}"#)
        await #expect(throws: BackendError.unauthorized) {
            try await backend.validateCredentials()
        }
    }

    @Test func knownErrorCodesGetReadableMessages() async {
        let (backend, transport) = makeBackend()
        await transport.stub("torrents/addMagnet", status: 403, json: #"{"error":"infringing_file","error_code":35}"#)
        await #expect(throws: BackendError.api(message: "Real-Debrid refused this file (infringing).")) {
            try await backend.add(.magnet("magnet:?xt=urn:btih:abc"))
        }
    }

    @Test func unknownErrorFallsBackToMessage() {
        #expect(RealDebridBackend.map(errorCode: 99, message: "new_thing") == .api(message: "Real-Debrid: new thing"))
        #expect(RealDebridBackend.map(errorCode: nil, message: nil) == nil)
    }

    @Test func fileSelectionFallsBackToAll() {
        let files = [RealDebridFile(id: 1, path: "/a/readme.txt", bytes: 1, selected: 0)]
        #expect(RealDebridFiles.selection(for: files) == "all")
    }

    @Test func itemRefRoundTrips() {
        #expect(RealDebridItemRef("torrent:AB12") == .torrent("AB12"))
        #expect(RealDebridItemRef("download:X")?.id == "download:X")
        #expect(RealDebridItemRef("torrent:") == nil)
    }
}
