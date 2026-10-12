import Foundation

/// Client for one Stremio addon, addressed by its manifest URL.
///
/// Routes (Stremio addon protocol): `{base}/catalog/{type}/{id}[/{extra}].json`, `{base}/meta/{type}/{id}.json`,
/// `{base}/stream/{type}/{id}.json`, where `{base}` is the manifest URL without `/manifest.json`.
/// Manifest URLs often embed the user's tokens and config in the path: keep them in the Keychain, never log them.
public struct StremioAddon: Sendable {
    public let manifestURL: URL
    public let manifest: StremioManifest
    private let transport: any HTTPTransport

    public init(manifestURL: URL, manifest: StremioManifest, transport: any HTTPTransport = URLSession.shared) {
        self.manifestURL = manifestURL
        self.manifest = manifest
        self.transport = transport
    }

    /// Fetches the manifest and returns a ready client.
    public static func load(manifestURL: URL, transport: any HTTPTransport = URLSession.shared) async throws -> StremioAddon {
        guard manifestURL.path().hasSuffix("/manifest.json") else {
            throw BackendError.api(message: "An addon URL ends with /manifest.json.")
        }
        let manifest = try await fetch(StremioManifest.self, from: manifestURL, transport: transport)
        return StremioAddon(manifestURL: manifestURL, manifest: manifest, transport: transport)
    }

    // MARK: - Resources

    /// Searches the addon's plain search catalog for a type. Empty when the addon cannot search that type.
    public func search(_ query: String, type: MediaType) async throws -> [MediaSummary] {
        guard let catalog = manifest.searchCatalog(for: type) else { return [] }
        let url = resourceURL("catalog", type: type.rawValue, id: catalog.id, extra: ["search": query])
        let response = try await Self.fetch(StremioMetasResponse.self, from: url, transport: transport)
        return response.metas.compactMap(\.summary)
    }

    public func meta(type: MediaType, id: String) async throws -> MediaDetail {
        let url = resourceURL("meta", type: type.rawValue, id: id)
        let response = try await Self.fetch(StremioMetaResponse.self, from: url, transport: transport)
        guard let detail = response.meta.detail else { throw BackendError.invalidResponse }
        return detail
    }

    /// Streams for a movie ID or an episode ID (`tt…:season:episode`).
    public func streams(type: MediaType, id: String) async throws -> [StreamCandidate] {
        let url = resourceURL("stream", type: type.rawValue, id: id)
        let response = try await Self.fetch(StremioStreamsResponse.self, from: url, transport: transport)
        return response.streams.enumerated().map { index, stream in
            stream.candidate(id: "\(manifest.id)#\(index)")
        }
    }

    // MARK: - Helpers

    var baseURLString: String {
        String(manifestURL.absoluteString.dropLast("/manifest.json".count))
    }

    func resourceURL(_ resource: String, type: String, id: String, extra: [String: String] = [:]) -> URL {
        var path = "\(baseURLString)/\(resource)/\(Self.encode(type))/\(Self.encode(id))"
        if !extra.isEmpty {
            path += "/" + extra.sorted { $0.key < $1.key }
                .map { "\(Self.encode($0.key))=\(Self.encode($0.value))" }
                .joined(separator: "&")
        }
        return URL(string: path + ".json")!
    }

    /// Like JavaScript's `encodeURIComponent`, which is what Stremio uses for path segments and extras.
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        // `:` must survive in IDs like `tt123:1:2`; addons route on it literally.
        allowed.insert(":")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func fetch<T: Decodable>(_ type: T.Type, from url: URL, transport: any HTTPTransport) async throws -> T {
        var request = URLRequest(url: url)
        // Debrid-backed stream addons resolve on the fly and can be slow.
        request.timeoutInterval = 45
        let (data, response) = try await transport.send(request)
        if let error = response.backendError { throw error }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw BackendError.invalidResponse
        }
    }
}
