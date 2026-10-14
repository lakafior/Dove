import Foundation

/// A Kodi on the user's network, stored as JSON under `CredentialKey.kodi` (it carries the password).
public struct KodiServer: Codable, Sendable, Equatable {
    /// `192.168.1.20`, `kodi.local`, or a full `http://host:port` address.
    public var host: String
    public var port: Int
    public var username: String
    public var password: String

    public static let defaultPort = 8080

    public init(host: String, port: Int = KodiServer.defaultPort, username: String = "kodi", password: String = "") {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    /// `http://host:port/jsonrpc`. A host typed with a scheme or port keeps them.
    public var endpoint: URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard var components = URLComponents(string: trimmed.contains("://") ? trimmed : "http://\(trimmed)"),
              components.host?.isEmpty == false else { return nil }
        if components.port == nil { components.port = port }
        components.path = "/jsonrpc"
        return components.url
    }

    /// Where Kodi was looked for, for messages.
    var address: String {
        endpoint.map { "\($0.host() ?? host):\($0.port ?? port)" } ?? host
    }
}

/// Plays links on Kodi through its JSON-RPC API (`POST /jsonrpc`). Kodi needs Settings › Services › Control ›
/// "Allow remote control via HTTP" on, and from Kodi 19 a password for it.
public struct KodiClient: Sendable {
    public let server: KodiServer
    private let transport: any HTTPTransport

    /// Kodi's video playlist.
    static let videoPlaylist = 1

    public init(server: KodiServer, transport: any HTTPTransport = URLSession.shared) {
        self.server = server
        self.transport = transport
    }

    /// Checks that Kodi answers and accepts the login.
    public func ping() async throws {
        _ = try await call("JSONRPC.Ping")
    }

    /// One entry plays directly; several replace the video playlist and start it from the first.
    /// File names are not sent: Kodi has no title parameter for a streamed file.
    public func play(_ entries: [PlayEntry]) async throws {
        guard let first = entries.first else { return }
        if entries.count == 1 {
            _ = try await call("Player.Open", ["item": ["file": first.url.absoluteString]])
            return
        }
        _ = try await call("Playlist.Clear", ["playlistid": Self.videoPlaylist])
        _ = try await call("Playlist.Add", [
            "playlistid": Self.videoPlaylist,
            "item": entries.map { ["file": $0.url.absoluteString] },
        ])
        _ = try await call("Player.Open", ["item": ["playlistid": Self.videoPlaylist, "position": 0]])
    }

    private func call(_ method: String, _ params: [String: Any]? = nil) async throws -> Any? {
        guard let endpoint = server.endpoint else {
            throw BackendError.api(message: "Enter Kodi's address.")
        }
        var body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method]
        if let params { body["params"] = params }

        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        if !server.username.isEmpty || !server.password.isEmpty {
            let login = Data("\(server.username):\(server.password)".utf8).base64EncodedString()
            request.setValue("Basic \(login)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError where error.code != .cancelled {
            throw BackendError.api(message:
                "Kodi did not answer at \(server.address). Check the address, that Kodi is running, and that Settings › Services › Control › Allow remote control via HTTP is on.")
        }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw BackendError.api(message: "Kodi rejected the user name or password (Settings › Services › Control).")
        case 404: throw BackendError.api(message: "\(server.address) answered, but not as Kodi's web server. Check the port.")
        default: throw response.backendError ?? BackendError.invalidResponse
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackendError.invalidResponse
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown error"
            throw BackendError.api(message: "Kodi refused \(method): \(message)")
        }
        return object["result"]
    }
}
