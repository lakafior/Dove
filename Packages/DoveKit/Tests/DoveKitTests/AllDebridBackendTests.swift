import Foundation
import Testing
@testable import DoveKit

/// Fixtures follow docs.alldebrid.com (`alldebrid_hosts` is a live, trimmed answer); not yet checked against a
/// live account.
struct AllDebridBackendTests {
    private func makeBackend() -> (AllDebridBackend, MockTransport) {
        let transport = MockTransport()
        return (AllDebridBackend(apiKey: "test-key", transport: transport, delayedInterval: .zero, delayedAttempts: 3), transport)
    }

    private func form(_ request: URLRequest) -> [(String, String)] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        return (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    }

    private func value(_ name: String, in request: URLRequest) -> String? {
        form(request).first { $0.0 == name }?.1
    }

    @Test func uploadsAMagnet() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("magnet/upload", json: #"{"status":"success","data":{"magnets":[{"magnet":"m","hash":"h","name":"Show","size":5,"ready":false,"id":101}]}}"#)

        let id = try await backend.add(.magnet("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"))

        #expect(id == "magnet:101")
        let sent = try #require(await transport.requests.last)
        #expect(sent.url?.path() == "/v4/magnet/upload")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(value("magnets[]", in: sent) == "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
    }

    @Test func uploadErrorsArePerMagnet() async {
        let (backend, transport) = makeBackend()
        await transport.stub("magnet/upload", json: #"{"status":"success","data":{"magnets":[{"magnet":"m","error":{"code":"MAGNET_TOO_MANY_ACTIVE","message":"Too many"}}]}}"#)
        await #expect(throws: BackendError.api(message: "Too many active torrents on AllDebrid (30 at most).")) {
            try await backend.add(.magnet("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"))
        }
    }

    @Test func torrentFilesGoAsMultipart() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("magnet/upload/file", json: #"{"status":"success","data":{"files":[{"file":"a.torrent","name":"A","hash":"h","id":7,"size":1,"ready":true}]}}"#)
        let id = try await backend.add(.torrentFile(data: Data("d4:infoe".utf8), filename: "a.torrent"))
        #expect(id == "magnet:7")
        let body = String(decoding: try #require(await transport.requests.last?.httpBody), as: UTF8.self)
        #expect(body.contains(#"name="files[0]"; filename="a.torrent""#))
    }

    @Test func hosterLinkIsUnlockedThenSaved() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("link/unlock", json: #"{"status":"success","data":{"link":"https://dl.alldebrid.com/x","filename":"f.mkv","filesize":5,"host":"1fichier"}}"#)
        await transport.stub("user/links/save", json: #"{"status":"success","data":{"message":"Link(s) saved"}}"#)

        let id = try await backend.add(.hosterURL(URL(string: "https://1fichier.com/?abc123")!, password: "pw"))

        #expect(id == "link:https://1fichier.com/?abc123")
        let requests = await transport.requests
        #expect(value("password", in: requests[0]) == "pw")
        #expect(value("links[]", in: requests[1]) == "https://1fichier.com/?abc123")
    }

    @Test func folderLinksSaveEveryFile() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("link/unlock", status: 400, json: #"{"status":"error","error":{"code":"LINK_HOST_NOT_SUPPORTED","message":"no"}}"#)
        await transport.stub("link/redirector", json: #"{"status":"success","data":{"links":["https://redirect.alldebrid.com/a","https://redirect.alldebrid.com/b"]}}"#)
        await transport.stub("user/links/save", json: #"{"status":"success","data":{"message":"ok"}}"#)

        let ids = try await backend.addAll(.hosterURL(URL(string: "https://folder.example/f/1")!), category: nil, privateTracker: false)

        #expect(ids == ["link:https://redirect.alldebrid.com/a", "link:https://redirect.alldebrid.com/b"])
        let save = try #require(await transport.requests.last)
        #expect(form(save).filter { $0.0 == "links[]" }.count == 2)
    }

    @Test func unsupportedHosterKeepsItsError() async {
        let (backend, transport) = makeBackend()
        await transport.stub("link/unlock", status: 400, json: #"{"status":"error","error":{"code":"LINK_HOST_NOT_SUPPORTED","message":"no"}}"#)
        await transport.stub("link/redirector", status: 400, json: #"{"status":"error","error":{"code":"REDIRECTOR_NOT_SUPPORTED","message":"no"}}"#)
        await #expect(throws: BackendError.api(message: "AllDebrid does not support this hoster.")) {
            try await backend.add(.hosterURL(URL(string: "https://example.com/f")!))
        }
    }

    @Test func libraryMergesMagnetsAndSavedLinks() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("magnet/status", body: try Fixture.data("alldebrid_magnet_status"))
        await transport.stub("user/links", body: try Fixture.data("alldebrid_user_links"))

        let items = try await backend.items()

        #expect(items.map(\.id) == ["link:https://1fichier.com/?abc123", "magnet:101", "magnet:102", "magnet:103"])
        #expect(items[1].status == .downloading(progress: 0.25))
        #expect(items[1].downloadSpeed == 5_000_000)
        // 3 GB left at 5 MB/s.
        #expect(items[1].secondsLeft == 600)
        #expect(items[2].downloadSpeed == nil, "0 means not downloading")
        #expect(items[1].infoHash == "0123456789abcdef0123456789abcdef01234567")
        #expect(items[2].status == .ready)
        #expect(items[3].status == .failed(reason: "File not available - no peer"))
        #expect(items[0].files == [LibraryFile(id: "0", name: "single.mkv", size: 734003200)])
        #expect(await transport.requests.contains { $0.url?.path() == "/v4.1/magnet/status" })
    }

    @Test func readyMagnetListsItsFilesWithoutTheRootFolder() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("magnet/status", body: try Fixture.data("alldebrid_magnet_status"))
        await transport.stub("magnet/files", body: try Fixture.data("alldebrid_magnet_files"))

        let item = try await backend.item("magnet:102")

        #expect(item.files == [
            LibraryFile(id: "0", name: "Movie.2024.2160p.mkv", size: 19990000000),
            LibraryFile(id: "1", name: "Subs/en.srt", size: 50000),
        ])
    }

    @Test func aSingleMagnetMayComeAsAnObject() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("magnet/status", json: #"{"status":"success","data":{"magnets":{"id":101,"filename":"Show","size":10,"status":"Downloading","statusCode":1,"downloaded":5}}}"#)
        #expect(try await backend.item("magnet:101").status == .downloading(progress: 0.5))
    }

    @Test func downloadUnlocksTheFilesLink() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("magnet/files", body: try Fixture.data("alldebrid_magnet_files"))
        await transport.stub("link/unlock", json: #"{"status":"success","data":{"link":"https://dl.alldebrid.com/sub","filename":"en.srt"}}"#)

        let request = try await backend.downloadRequest(itemID: "magnet:102", fileID: "1")

        #expect(request.url?.absoluteString == "https://dl.alldebrid.com/sub")
        #expect(value("link", in: try #require(await transport.requests.last)) == "https://alldebrid.com/f/BBB")
    }

    @Test func delayedLinksArePolled() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("link/unlock", json: #"{"status":"success","data":{"link":"","filename":"f","delayed":55}}"#)
        await transport.stub("link/delayed", json: #"{"status":"success","data":{"status":1,"time_left":10}}"#)
        await transport.stub("link/delayed", json: #"{"status":"success","data":{"status":2,"link":"https://dl.alldebrid.com/late"}}"#)

        let url = try await backend.unlock("https://hoster.example/f", password: nil)

        #expect(url.absoluteString == "https://dl.alldebrid.com/late")
    }

    @Test func deletesMagnetsAndSavedLinks() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("magnet/delete", json: #"{"status":"success","data":{"message":"deleted"}}"#)
        await transport.stub("user/links/delete", json: #"{"status":"success","data":{"message":"deleted"}}"#)

        try await backend.delete("magnet:102")
        try await backend.delete("link:https://1fichier.com/?abc123")

        let requests = await transport.requests
        #expect(value("id", in: requests[0]) == "102")
        #expect(value("links[]", in: requests[1]) == "https://1fichier.com/?abc123")
    }

    @Test func badKeyIsUnauthorized() async {
        let (backend, transport) = makeBackend()
        await transport.stub("v4/user", status: 401, json: #"{"status":"error","error":{"code":"AUTH_BAD_APIKEY","message":"bad"}}"#)
        await #expect(throws: BackendError.unauthorized) { try await backend.validateCredentials() }
    }

    @Test func accountReadsPremiumUntilEvenAsAString() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("v4/user", json: #"{"status":"success","data":{"user":{"username":"u","isPremium":true,"premiumUntil":"4102444800"}}}"#)
        let account = try await backend.account()
        #expect(account.isPremium)
        #expect(account.premiumUntil == Date(timeIntervalSince1970: 4102444800))
    }

    @Test func hostsComeFromThePublicList() async throws {
        let (backend, transport) = makeBackend()
        await transport.stub("v4/hosts", body: try Fixture.data("alldebrid_hosts"))
        let hosts = try await backend.hostList()
        // Rapidgator's live status varies; what matters is that its alias domain is known.
        #expect(hosts.verdict(for: URL(string: "https://rg.to/file/abc")!) != .unsupported)
        #expect(hosts.verdict(for: URL(string: "https://1fichier.com/?abc")!) == .supported("1fichier"))
        #expect(hosts.verdict(for: URL(string: "https://example.com/f")!) == .unsupported)
    }

    @Test func nzbsAreNotTaken() {
        #expect(!AllDebridBackend(apiKey: "k").supportedSources.contains(.nzb))
    }
}
