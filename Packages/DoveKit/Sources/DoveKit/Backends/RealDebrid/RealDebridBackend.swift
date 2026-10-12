import Foundation

/// Real-Debrid adapter. API docs: https://api.real-debrid.com
///
/// - Auth: `Authorization: Bearer <key>`, base `https://api.real-debrid.com/rest/1.0`. Limit: 250 requests/minute.
/// - Add magnet: `POST /torrents/addMagnet` (form `magnet`) → id; then `POST /torrents/selectFiles/{id}`
///   with the video file IDs (samples and extras skipped). There is no cache-check endpoint anymore:
///   add, then poll `GET /torrents/info/{id}` — `status == "downloaded"` right away means it was cached.
/// - Add .torrent: `PUT /torrents/addTorrent` (raw body).
/// - Hoster link: `POST /unrestrict/link` (form `link`) creates an entry in `/downloads`.
/// - List: `GET /torrents` and `GET /downloads` (paginated: `page`, `limit` ≤ 5000). The list has no files;
///   `item(_:)` fetches `GET /torrents/info/{id}`.
/// - Delete: `DELETE /torrents/delete/{id}` or `DELETE /downloads/delete/{id}`.
/// - Download: the torrent's `links[i]` belongs to its i-th selected file → `POST /unrestrict/link` → `download`.
///
/// `451 infringing_file` (code 35) on an add means one of two things (measured by Debrid Media Manager):
/// the release name matches RD's filter (`RealDebridNameFilter`, refused every time), or RD is pausing
/// all adds on the account for 20 s to ~5 min. RD judges the torrent's real name, not the magnet's `dn`, so without
/// a known blocked name the two cannot be told apart. Dove does not wait it out silently: it says so at once.
public struct RealDebridBackend: LibraryBackend {
    public let id: BackendID = .realDebrid
    public let supportedSources: Set<SourceKind> = [.torrent, .hoster]

    private let apiKey: String
    private let transport: any HTTPTransport
    private let baseURL: URL
    /// File selection needs the magnet converted first; poll this many times before leaving it to the user.
    private let selectionAttempts: Int
    private let selectionInterval: Duration
    private let requestTimeout: TimeInterval

    static let pageSize = 1000

    public init(
        apiKey: String,
        transport: any HTTPTransport = URLSession.shared,
        baseURL: URL = URL(string: "https://api.real-debrid.com/rest/1.0")!,
        selectionAttempts: Int = 5,
        selectionInterval: Duration = .seconds(1),
        requestTimeout: TimeInterval = 30
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.baseURL = baseURL
        self.selectionAttempts = selectionAttempts
        self.selectionInterval = selectionInterval
        self.requestTimeout = requestTimeout
    }

    // MARK: - LibraryBackend

    public func validateCredentials() async throws {
        _ = try await send(request("user"))
    }

    @discardableResult
    public func add(_ source: Source) async throws -> LibraryItem.ID {
        switch source {
        case .magnet(let magnet):
            let created = try await addRefusingBlockedNames(
                request("torrents/addMagnet", method: "POST", form: [("magnet", magnet)]),
                name: RealDebridNameFilter.displayName(ofMagnet: magnet)
            )
            try await selectFilesWhenReady(created.id)
            return RealDebridItemRef.torrent(created.id).id

        case .torrentFile(let data, _):
            let created = try await addRefusingBlockedNames(
                request("torrents/addTorrent", method: "PUT", body: data, contentType: "application/x-bittorrent"),
                name: nil
            )
            try await selectFilesWhenReady(created.id)
            return RealDebridItemRef.torrent(created.id).id

        case .torrentURL(let url):
            // Real-Debrid wants the file itself, so fetch it first.
            let (data, response) = try await transport.send(URLRequest(url: url))
            if let error = response.backendError { throw error }
            return try await add(.torrentFile(data: data, filename: url.lastPathComponent))

        case .hosterURL(let url):
            let download = try await unrestrict(url.absoluteString)
            return RealDebridItemRef.download(download.id).id

        case .nzbURL, .nzbFile:
            throw BackendError.unsupportedSource(.nzb)
        }
    }

    public func items() async throws -> [LibraryItem] {
        async let torrents = paged(RealDebridTorrent.self, path: "torrents")
        async let downloads = paged(RealDebridDownload.self, path: "downloads")
        let all = try await torrents.map(\.libraryItem) + downloads.map(\.libraryItem)
        return all.sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
    }

    public func item(_ itemID: LibraryItem.ID) async throws -> LibraryItem {
        guard let ref = RealDebridItemRef(itemID) else { throw BackendError.notFound }
        switch ref {
        case .torrent(let id):
            return try await info(id).libraryItem
        case .download(let id):
            return try await findDownload(id).libraryItem
        }
    }

    public func delete(_ itemID: LibraryItem.ID) async throws {
        guard let ref = RealDebridItemRef(itemID) else { throw BackendError.notFound }
        let path = switch ref {
        case .torrent(let id): "torrents/delete/\(id)"
        case .download(let id): "downloads/delete/\(id)"
        }
        _ = try await send(request(path, method: "DELETE"))
    }

    public func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
        guard let ref = RealDebridItemRef(itemID) else { throw BackendError.notFound }
        let link: String
        switch ref {
        case .torrent(let id):
            let torrent = try await info(id)
            let selected = (torrent.files ?? []).filter { $0.selected == 1 }.sorted { $0.id < $1.id }
            guard let index = selected.firstIndex(where: { String($0.id) == fileID }) else {
                throw BackendError.notFound
            }
            guard let links = torrent.links, index < links.count else {
                throw BackendError.api(message: "Real-Debrid has not finished this torrent yet.")
            }
            link = try await unrestrict(links[index]).download
        case .download(let id):
            link = try await findDownload(id).download
        }
        guard let url = URL(string: link) else { throw BackendError.invalidResponse }
        return URLRequest(url: url)
    }

    // MARK: - Helpers

    static let blockedNameMessage =
        "Real-Debrid blocks releases tagged WEB-DL, WEBRip, BDRip and similar. Pick another release or send it to TorBox."
    static let refusedMessage =
        "Real-Debrid refused this torrent. Either its release name is blocked (WEB-DL, WEBRip and similar), or Real-Debrid is pausing adds on your account for a few minutes. Try again in a minute, or send it to TorBox."

    /// Sends an add (`addMagnet` / `addTorrent`). A known blocked name is refused before calling RD.
    private func addRefusingBlockedNames(_ request: URLRequest, name: String?) async throws -> RealDebridCreated {
        if let name, RealDebridNameFilter.isBlocked(name) {
            throw BackendError.api(message: Self.blockedNameMessage)
        }
        do {
            return try await decode(RealDebridCreated.self, from: request)
        } catch BackendError.api(let message) where message == Self.infringingMessage {
            throw BackendError.api(message: Self.refusedMessage)
        }
    }

    private func info(_ torrentID: String) async throws -> RealDebridTorrent {
        try await decode(RealDebridTorrent.self, from: request("torrents/info/\(torrentID)"))
    }

    private func unrestrict(_ link: String) async throws -> RealDebridDownload {
        try await decode(RealDebridDownload.self, from: request("unrestrict/link", method: "POST", form: [("link", link)]))
    }

    /// `/downloads` has no single-entry endpoint, so look the entry up in the list.
    private func findDownload(_ id: String) async throws -> RealDebridDownload {
        guard let match = try await paged(RealDebridDownload.self, path: "downloads").first(where: { $0.id == id }) else {
            throw BackendError.notFound
        }
        return match
    }

    /// Selects video files once the magnet is converted. Gives up quietly if conversion takes longer;
    /// the item then shows as queued and the user can retry from Real-Debrid.
    // TODO(stage-1): offer "select files" in the item view for torrents left in waiting_files_selection.
    private func selectFilesWhenReady(_ torrentID: String) async throws {
        for attempt in 0..<selectionAttempts {
            let torrent = try await info(torrentID)
            switch torrent.status {
            case "waiting_files_selection":
                let files = RealDebridFiles.selection(for: torrent.files ?? [])
                _ = try await send(request("torrents/selectFiles/\(torrentID)", method: "POST", form: [("files", files)]))
                return
            case "magnet_conversion", "queued":
                if attempt < selectionAttempts - 1 { try await Task.sleep(for: selectionInterval) }
            default:
                return
            }
        }
    }

    private func paged<T: Decodable>(_ type: T.Type, path: String) async throws -> [T] {
        var result: [T] = []
        var page = 1
        while true {
            let query = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: String(Self.pageSize))]
            let data = try await send(request(path, query: query))
            // Past the last page Real-Debrid answers 204 with an empty body.
            guard !data.isEmpty else { break }
            let batch = try decode([T].self, data: data)
            result += batch
            guard batch.count == Self.pageSize else { break }
            page += 1
        }
        return result
    }

    private func request(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        form: [(String, String)]? = nil,
        body: Data? = nil,
        contentType: String? = nil
    ) -> URLRequest {
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let form {
            request.httpBody = FormURLEncoded.encode(form)
            request.setValue(FormURLEncoded.contentType, forHTTPHeaderField: "Content-Type")
        } else if let body {
            request.httpBody = body
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        }
        return request
    }

    /// Sends the request and maps failures. Real-Debrid errors are `{"error": "...", "error_code": n}` with a 4xx/5xx.
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.send(request)
        guard let httpError = response.backendError else { return data }
        let body = try? Self.decoder.decode(RealDebridErrorBody.self, from: data)
        throw Self.map(errorCode: body?.errorCode, message: body?.error) ?? httpError
    }

    private func decode<T: Decodable>(_ type: T.Type, from request: URLRequest) async throws -> T {
        try decode(type, data: try await send(request))
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        do {
            return try Self.decoder.decode(type, from: data)
        } catch {
            throw BackendError.invalidResponse
        }
    }

    /// Code 35 outside adds: `/unrestrict/link` refuses file names matching RD's filter.
    static let infringingMessage = "Real-Debrid blocks this file name, so it cannot be downloaded or streamed from Real-Debrid."

    static func map(errorCode: Int?, message: String?) -> BackendError? {
        switch errorCode {
        case 8, 12, 13: return .unauthorized
        case 7: return .notFound
        case 5, 34: return .rateLimited
        case 9: return .api(message: "Permission denied. Is your Real-Debrid premium active?")
        case 14: return .api(message: "Your Real-Debrid account is locked.")
        case 16: return .api(message: "Real-Debrid does not support this hoster.")
        case 17, 19: return .api(message: "The hoster is temporarily unavailable on Real-Debrid.")
        case 18: return .api(message: "Real-Debrid's limit for this hoster is reached.")
        case 20: return .api(message: "This hoster needs Real-Debrid premium.")
        case 21: return .api(message: "Too many active downloads on Real-Debrid.")
        case 23: return .api(message: "Your Real-Debrid traffic is exhausted.")
        case 24: return .api(message: "The file is unavailable on the hoster.")
        case 29: return .api(message: "The torrent is too big for Real-Debrid.")
        case 30: return .api(message: "Real-Debrid says the torrent file is invalid.")
        case 35: return .api(message: infringingMessage)
        case 36: return .api(message: "Real-Debrid fair usage limit reached.")
        default:
            guard let message, !message.isEmpty else { return nil }
            return .api(message: "Real-Debrid: \(message.replacingOccurrences(of: "_", with: " "))")
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
