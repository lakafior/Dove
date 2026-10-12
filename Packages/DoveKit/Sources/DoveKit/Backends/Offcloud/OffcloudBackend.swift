import Foundation

/// Offcloud adapter. Offcloud's own docs (https://github.com/Offcloud/offcloud-api) are thin; the behaviour here
/// follows Debrid Media Manager's live measurements (`src/services/offcloud.ts`, 2026-09).
///
/// - Auth: `Authorization: Bearer <key>`. `?key=` works too, but query strings end up in logs.
/// - Add magnet, torrent URL or hoster link: `POST /cloud` with JSON `{"url": …}`; `.torrent` bytes as multipart `file`.
///   A cached magnet answers `status: "downloaded"` at once. Offcloud accepts invalid magnets and never finishes
///   them, so the info hash is validated first.
/// - List: `GET /cloud/history` (no sizes, no progress). Account: `GET /account/info`.
/// - Files: folders via `GET /cloud/explore/{id}` (a bare array of signed URLs); a single file lives at
///   `https://{server}.offcloud.com/cloud/download/{id}/{fileName}`.
/// - Delete: `GET /cloud/remove/{id}` — destructive despite being a GET; only call it from a user action.
/// - Errors: `{"error": "…"}` (`NOAUTH` for any key problem); unknown paths answer with HTML, so check the content type.
public struct OffcloudBackend: LibraryBackend {
    public let id: BackendID = .offcloud
    public let supportedSources: Set<SourceKind> = [.torrent, .hoster]

    private let apiKey: String
    private let transport: any HTTPTransport
    private let baseURL: URL

    public init(
        apiKey: String,
        transport: any HTTPTransport = URLSession.shared,
        baseURL: URL = URL(string: "https://offcloud.com/api")!
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.baseURL = baseURL
    }

    // MARK: - LibraryBackend

    public func validateCredentials() async throws {
        let account = try await decode(OffcloudAccountInfo.self, from: request("account/info"))
        if account.isPremium == false {
            throw BackendError.api(message: "This Offcloud account is not premium.")
        }
    }

    @discardableResult
    public func add(_ source: Source) async throws -> LibraryItem.ID {
        let request: URLRequest
        switch source {
        case .magnet(let magnet):
            guard OffcloudMagnet.hasValidInfoHash(magnet) else {
                throw BackendError.api(message: "This magnet has no valid info hash.")
            }
            request = jsonRequest("cloud", body: ["url": magnet])
        case .torrentURL(let url), .hosterURL(let url):
            request = jsonRequest("cloud", body: ["url": url.absoluteString])
        case .torrentFile(let data, let filename):
            var form = MultipartFormData()
            form.addFile("file", filename: filename, mimeType: "application/x-bittorrent", data: data)
            request = self.request("cloud", method: "POST", body: form.finalized(), contentType: form.contentType)
        case .nzbURL, .nzbFile:
            throw BackendError.unsupportedSource(.nzb)
        }

        let result = try await decode(OffcloudAddResult.self, from: request)
        if let missing = result.notAvailable {
            throw BackendError.api(message: Self.notAvailableMessage(missing))
        }
        guard let requestID = result.requestId, !requestID.isEmpty else { throw BackendError.invalidResponse }
        return OffcloudItemRef.cloud(requestID).id
    }

    public func items() async throws -> [LibraryItem] {
        try await history().map { $0.libraryItem() }
    }

    public func item(_ itemID: LibraryItem.ID) async throws -> LibraryItem {
        let entry = try await historyEntry(itemID)
        guard entry.libraryStatus == .ready else { return entry.libraryItem() }
        let files = try await links(for: entry).enumerated().map { index, url in
            LibraryFile(id: String(index), name: url.lastPathComponent)
        }
        return entry.libraryItem(files: files)
    }

    public func delete(_ itemID: LibraryItem.ID) async throws {
        guard let ref = OffcloudItemRef(itemID) else { throw BackendError.notFound }
        _ = try await send(request("cloud/remove/\(ref.requestID)"))
    }

    public func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
        let links = try await links(for: historyEntry(itemID))
        guard let index = Int(fileID), links.indices.contains(index) else { throw BackendError.notFound }
        return URLRequest(url: links[index])
    }

    // MARK: - Helpers

    private func history() async throws -> [OffcloudHistoryItem] {
        try await decode([OffcloudHistoryItem].self, from: request("cloud/history"))
    }

    /// There is no single-item endpoint carrying `server` and `isDirectory`, so look the entry up in the history.
    private func historyEntry(_ itemID: LibraryItem.ID) async throws -> OffcloudHistoryItem {
        guard let ref = OffcloudItemRef(itemID) else { throw BackendError.notFound }
        guard let entry = try await history().first(where: { $0.requestId == ref.requestID }) else {
            throw BackendError.notFound
        }
        return entry
    }

    /// Download URLs for every file of a request, in a stable order (file IDs are indexes into it).
    private func links(for entry: OffcloudHistoryItem) async throws -> [URL] {
        if entry.isDirectory != false {
            do {
                let links = try await decode([String].self, from: request("cloud/explore/\(entry.requestId)"))
                return links.compactMap(URL.init(string:))
            } catch {
                // Explore answers "Bad archive" for a single file; fall back to its direct link when we can.
                guard entry.isDirectory == nil, let url = entry.singleFileURL else { throw error }
                return [url]
            }
        }
        guard let url = entry.singleFileURL else { throw BackendError.invalidResponse }
        return [url]
    }

    static func notAvailableMessage(_ reason: String) -> String {
        switch reason {
        case "premium": "Offcloud needs a premium add-on for this download."
        case "links": "Offcloud's link limit is reached for this account."
        case "proxy": "Offcloud needs a proxy add-on for this download."
        case "cloud": "Offcloud needs a cloud download upgrade for this download."
        case "video": "Offcloud needs a video site add-on for this download."
        default: "Offcloud cannot take this download (\(reason))."
        }
    }

    private func jsonRequest(_ path: String, body: [String: String]) -> URLRequest {
        let data = try? JSONSerialization.data(withJSONObject: body)
        return request(path, method: "POST", body: data, contentType: "application/json")
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String? = nil) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return request
    }

    /// Sends the request and maps failures. Returns the JSON body.
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.send(request)
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard contentType.contains("application/json") else {
            // HTML 404/405 pages, sometimes with a 200 status.
            throw response.backendError ?? BackendError.invalidResponse
        }
        let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        if let message = json as? String, response.backendError != nil {
            throw BackendError.api(message: "Offcloud: \(message.trimmingCharacters(in: .whitespaces))")
        }
        if let error = (json as? [String: Any])?["error"] as? String {
            // `error` never appears on a successful payload, whatever the status.
            if error == "NOAUTH" { throw BackendError.unauthorized }
            throw BackendError.api(message: "Offcloud: \(error)")
        }
        if let error = response.backendError { throw error }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from request: URLRequest) async throws -> T {
        let data = try await send(request)
        do {
            return try Self.decoder.decode(type, from: data)
        } catch {
            throw BackendError.invalidResponse
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
