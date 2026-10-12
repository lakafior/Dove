import Foundation

/// TorBox adapter. API docs: https://api-docs.torbox.app
///
/// Auth: `Authorization: Bearer <key>` on every call, except `requestdl`, which takes `token=<key>` as a query item.
/// Torrents and hoster links ("web downloads") live in separate endpoints; this adapter merges them into one library.
/// TODO(stage-3): TorBox also accepts NZBs (`/usenet/createusenetdownload`); add `.nzb` to `supportedSources` when implemented.
public struct TorBoxBackend: LibraryBackend {
    public let id: BackendID = .torBox
    public let supportedSources: Set<SourceKind> = [.torrent, .hoster]

    private let apiKey: String
    private let transport: any HTTPTransport
    private let baseURL: URL

    public init(
        apiKey: String,
        transport: any HTTPTransport = URLSession.shared,
        baseURL: URL = URL(string: "https://api.torbox.app/v1/api")!
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.baseURL = baseURL
    }

    // MARK: - LibraryBackend

    public func validateCredentials() async throws {
        _ = try await perform(request("user/me"), as: TorBoxIgnored.self)
    }

    @discardableResult
    public func add(_ source: Source) async throws -> LibraryItem.ID {
        switch source {
        case .magnet(let magnet):
            var form = MultipartFormData()
            form.addField("magnet", magnet)
            return try await createTorrent(form)

        case .torrentFile(let data, let filename):
            var form = MultipartFormData()
            form.addFile("file", filename: filename, mimeType: "application/x-bittorrent", data: data)
            return try await createTorrent(form)

        case .torrentURL(let url):
            // TorBox wants the file itself, so fetch it first.
            let (data, response) = try await transport.send(URLRequest(url: url))
            if let error = response.backendError { throw error }
            let filename = url.lastPathComponent.isEmpty ? "download.torrent" : url.lastPathComponent
            return try await add(.torrentFile(data: data, filename: filename))

        case .hosterURL(let url):
            var form = MultipartFormData()
            form.addField("link", url.absoluteString)
            let result = try await perform(
                request("webdl/createwebdownload", method: "POST", body: form.finalized(), contentType: form.contentType),
                as: TorBoxCreateResult.self
            )
            if let id = result?.webdownloadId { return TorBoxItemRef.webDownload(id).id }
            if let id = result?.queuedId { return TorBoxItemRef.queued(id).id }
            throw BackendError.invalidResponse

        case .nzbURL, .nzbFile:
            throw BackendError.unsupportedSource(.nzb)
        }
    }

    public func items() async throws -> [LibraryItem] {
        let bypass = [URLQueryItem(name: "bypass_cache", value: "true")]
        async let torrents = perform(request("torrents/mylist", query: bypass), as: [TorBoxTransfer].self)
        async let webDownloads = perform(request("webdl/mylist", query: bypass), as: [TorBoxTransfer].self)

        let torrentItems = (try await torrents ?? []).map { $0.libraryItem(ref: .torrent($0.id)) }
        let webItems = (try await webDownloads ?? []).map { $0.libraryItem(ref: .webDownload($0.id)) }

        return (torrentItems + webItems).sorted {
            ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast)
        }
    }

    public func delete(_ itemID: LibraryItem.ID) async throws {
        guard let ref = TorBoxItemRef(itemID) else { throw BackendError.notFound }
        let (path, body): (String, [String: Any]) = switch ref {
        case .torrent(let id): ("torrents/controltorrent", ["torrent_id": id, "operation": "delete"])
        case .webDownload(let id): ("webdl/controlwebdownload", ["webdl_id": id, "operation": "delete"])
        case .queued(let id): ("queued/controlqueued", ["queued_id": id, "operation": "delete"])
        }
        let json = try JSONSerialization.data(withJSONObject: body)
        _ = try await perform(
            request(path, method: "POST", body: json, contentType: "application/json"),
            as: TorBoxIgnored.self
        )
    }

    public func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
        guard let ref = TorBoxItemRef(itemID) else { throw BackendError.notFound }
        let (path, idName, id): (String, String, Int) = switch ref {
        case .torrent(let id): ("torrents/requestdl", "torrent_id", id)
        case .webDownload(let id): ("webdl/requestdl", "web_id", id)
        case .queued: throw BackendError.api(message: "This download is still queued on TorBox.")
        }
        let query = [
            URLQueryItem(name: "token", value: apiKey),
            URLQueryItem(name: idName, value: String(id)),
            URLQueryItem(name: "file_id", value: fileID),
            URLQueryItem(name: "zip_link", value: "false")
        ]
        guard let link = try await perform(request(path, query: query, authorized: false), as: String.self),
              let url = URL(string: link)
        else { throw BackendError.invalidResponse }
        return URLRequest(url: url)
    }

    // MARK: - Helpers

    private func createTorrent(_ form: MultipartFormData) async throws -> LibraryItem.ID {
        let result = try await perform(
            request("torrents/createtorrent", method: "POST", body: form.finalized(), contentType: form.contentType),
            as: TorBoxCreateResult.self
        )
        if let id = result?.torrentId { return TorBoxItemRef.torrent(id).id }
        if let id = result?.queuedId { return TorBoxItemRef.queued(id).id }
        throw BackendError.invalidResponse
    }

    private func request(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        authorized: Bool = true
    ) -> URLRequest {
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if authorized { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// Sends the request, maps HTTP errors, unwraps the envelope. Returns `data`, which may be nil on success.
    private func perform<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T? {
        let (data, response) = try await transport.send(request)
        if let error = response.backendError, response.statusCode != 400 {
            throw error
        }
        let envelope: TorBoxEnvelope<T>
        do {
            envelope = try Self.decoder.decode(TorBoxEnvelope<T>.self, from: data)
        } catch {
            throw response.backendError ?? BackendError.invalidResponse
        }
        guard envelope.success else {
            throw BackendError.api(message: envelope.detail ?? envelope.error ?? "TorBox request failed")
        }
        return envelope.data
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
