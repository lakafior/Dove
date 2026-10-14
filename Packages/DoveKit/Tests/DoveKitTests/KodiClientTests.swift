import Foundation
import Testing
@testable import DoveKit

struct KodiClientTests {
    private let server = KodiServer(host: "192.168.1.20", username: "kodi", password: "secret")
    private let ok = #"{"id":1,"jsonrpc":"2.0","result":"OK"}"#

    private func body(_ request: URLRequest) -> String {
        String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    }

    @Test func endpointFromHostOrAddress() {
        #expect(KodiServer(host: "192.168.1.20").endpoint?.absoluteString == "http://192.168.1.20:8080/jsonrpc")
        #expect(KodiServer(host: " kodi.local ", port: 8081).endpoint?.absoluteString == "http://kodi.local:8081/jsonrpc")
        #expect(KodiServer(host: "https://kodi.example:443/").endpoint?.absoluteString == "https://kodi.example:443/jsonrpc")
        #expect(KodiServer(host: "").endpoint == nil)
    }

    @Test func pingPostsJSONRPCWithBasicAuth() async throws {
        let transport = MockTransport()
        await transport.stub("/jsonrpc", json: #"{"id":1,"jsonrpc":"2.0","result":"pong"}"#)

        try await KodiClient(server: server, transport: transport).ping()

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://192.168.1.20:8080/jsonrpc")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic a29kaTpzZWNyZXQ=")
        #expect(body(request) == #"{"id":1,"jsonrpc":"2.0","method":"JSONRPC.Ping"}"#)
    }

    @Test func oneEntryOpensTheFile() async throws {
        let transport = MockTransport()
        await transport.stub("/jsonrpc", json: ok)

        try await KodiClient(server: server, transport: transport)
            .play([PlayEntry(url: URL(string: "https://dl.example/a.mkv")!, filename: "A.mkv")])

        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(body(requests[0]) == #"{"id":1,"jsonrpc":"2.0","method":"Player.Open","params":{"item":{"file":"https:\/\/dl.example\/a.mkv"}}}"#)
    }

    @Test func severalEntriesReplaceTheVideoPlaylist() async throws {
        let transport = MockTransport()
        await transport.stub("/jsonrpc", json: ok)

        try await KodiClient(server: server, transport: transport).play([
            PlayEntry(url: URL(string: "https://dl.example/1.mkv")!),
            PlayEntry(url: URL(string: "https://dl.example/2.mkv")!),
        ])

        let bodies = await transport.requests.map(body)
        #expect(bodies == [
            #"{"id":1,"jsonrpc":"2.0","method":"Playlist.Clear","params":{"playlistid":1}}"#,
            #"{"id":1,"jsonrpc":"2.0","method":"Playlist.Add","params":{"item":[{"file":"https:\/\/dl.example\/1.mkv"},{"file":"https:\/\/dl.example\/2.mkv"}],"playlistid":1}}"#,
            #"{"id":1,"jsonrpc":"2.0","method":"Player.Open","params":{"item":{"playlistid":1,"position":0}}}"#,
        ])
    }

    @Test func noLoginNoAuthorizationHeader() async throws {
        let transport = MockTransport()
        await transport.stub("/jsonrpc", json: ok)

        try await KodiClient(server: KodiServer(host: "kodi.local", username: ""), transport: transport).ping()

        #expect(await transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func wrongLoginIsExplained() async {
        let transport = MockTransport()
        await transport.stub("/jsonrpc", status: 401, json: "")
        await #expect(throws: BackendError.api(message: "Kodi rejected the user name or password (Settings › Services › Control).")) {
            try await KodiClient(server: server, transport: transport).ping()
        }
    }

    @Test func jsonRPCErrorCarriesKodisMessage() async {
        let transport = MockTransport()
        await transport.stub("/jsonrpc", json: #"{"error":{"code":-32602,"message":"Invalid params."},"id":1,"jsonrpc":"2.0"}"#)
        await #expect(throws: BackendError.api(message: "Kodi refused Player.Open: Invalid params.")) {
            try await KodiClient(server: server, transport: transport).play([PlayEntry(url: URL(string: "https://x.example/a")!)])
        }
    }

    @Test func unreachableKodiPointsAtTheSetting() async throws {
        // No stub: MockTransport throws a URLError.
        let error = await #expect(throws: BackendError.self) {
            try await KodiClient(server: server, transport: MockTransport()).ping()
        }
        #expect(error?.localizedDescription.contains("192.168.1.20:8080") == true)
        #expect(error?.localizedDescription.contains("Allow remote control via HTTP") == true)
    }
}
