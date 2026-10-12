import Foundation

/// nzbdav adapter. nzbdav emulates the SABnzbd API and mounts finished jobs over WebDAV.
/// Source: https://github.com/nzbdav-dev/nzbdav (behaviour below checked against its controllers).
///
/// - API: `POST {base}/api?mode=…&output=json&…` with the API key alone in a form body, so it stays out of URLs
///   and server logs. The other parameters must be in the query: nzbdav reads `addurl`'s `name` and the
///   delete `value`s only from there (checked live: in the body they arrive empty, and a delete "succeeds"
///   without deleting). The NZB link therefore lands in the query, as with Sonarr and Radarr.
///   Errors are `{"status": false, "error": "…"}`, 401 for a wrong key.
/// - Add: `mode=addurl` (`name` = NZB link, nzbdav fetches it) or `mode=addfile` (multipart `nzbFile`).
///   Without `cat` the job goes to nzbdav's manual-upload category. Answer: `nzo_ids`.
/// - List: `mode=queue` (in progress), `mode=history` (`Completed` / `Failed` with `fail_message`), and every job
///   folder under `/content/{category}/`. nzbdav keeps a job's files after its history entry is cleared
///   (without "delete files", or by another client), so the folders are the real library: a folder without a
///   history entry is listed as its own item (`dav:` ID). History has no dates; folder modification times do.
/// - Files: WebDAV `PROPFIND` under `/content/{category}/{job name}/`, Basic Auth. The category must match
///   the history's spelling (`Tv` and `TV` can both exist). `href`s carry the server's internal host.
/// - Download: `GET` the WebDAV path with Basic Auth (ranges work). Infuse gets the same URL with the
///   credentials in it, since nzbdav's key-signed `/view` links need a key the SABnzbd API does not expose.
/// - Delete: `mode=queue&name=delete` or `mode=history&name=delete&del_completed_files=1`; a folder without a
///   history entry with WebDAV `DELETE`, which nzbdav refuses (403) while "Enforce read-only" is on (its default).
public struct NzbdavBackend: LibraryBackend {
    public let id: BackendID = .nzbdav
    public let supportedSources: Set<SourceKind> = [.nzb]

    private let baseURL: URL
    private let apiKey: String
    private let webDAV: WebDAVClient
    private let transport: any HTTPTransport

    static let contentRoot = "/content"

    public init(
        baseURL: URL,
        apiKey: String,
        webDAVUser: String,
        webDAVPassword: String,
        transport: any HTTPTransport = URLSession.shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.transport = transport
        webDAV = WebDAVClient(baseURL: baseURL, user: webDAVUser, password: webDAVPassword, transport: transport)
    }

    // MARK: - LibraryBackend

    /// Checks both secrets: the API key (queue) and the WebDAV login (root listing).
    public func validateCredentials() async throws {
        _ = try await queue()
        _ = try await webDAV.list("/")
    }

    @discardableResult
    public func add(_ source: Source) async throws -> LibraryItem.ID {
        let created: NzbdavAdded
        switch source {
        case .nzbURL(let url):
            created = try await call("addurl", [("name", url.absoluteString)], as: NzbdavAdded.self)
        case .nzbFile(let data, let filename):
            var form = MultipartFormData()
            form.addField("apikey", apiKey)
            form.addFile("nzbFile", filename: filename, mimeType: "application/x-nzb", data: data)
            created = try await decode(NzbdavAdded.self, from: apiRequest(
                query: query("addfile", []),
                body: form.finalized(),
                contentType: form.contentType
            ))
        default:
            throw BackendError.unsupportedSource(source.kind)
        }
        guard let id = created.nzoIds?.first else { throw BackendError.api(message: "nzbdav did not accept the NZB.") }
        return NzbdavItemRef(nzoID: id).id
    }

    public func items() async throws -> [LibraryItem] {
        async let queued = queue()
        async let finished = history()
        let history = try await finished
        let folders = await jobFolders()
        let byPath = Dictionary(folders.map { (WebDAVClient.normalized($0.path), $0) }, uniquingKeysWith: { first, _ in first })
        let inHistory = Set(history.map(\.folderPath))
        let orphans = folders
            .filter { !inHistory.contains(WebDAVClient.normalized($0.path)) }
            .map { folder in
                LibraryItem(
                    id: NzbdavItemRef.folder(WebDAVClient.normalized(folder.path)).id,
                    backend: .nzbdav,
                    name: folder.name,
                    status: .ready,
                    addedAt: folder.modified
                )
            }
        return try await queued.map(\.libraryItem)
            + history.map { $0.libraryItem(addedAt: byPath[$0.folderPath]?.modified) }
            + orphans
    }

    /// A job with its files. Queued jobs have none yet; failed ones never get any.
    public func item(_ itemID: LibraryItem.ID) async throws -> LibraryItem {
        switch NzbdavItemRef(itemID) {
        case .job(let nzoID):
            if let slot = try await queue().first(where: { $0.nzoId == nzoID }) { return slot.libraryItem }
            guard let slot = try await history(ids: [nzoID]).first(where: { $0.nzoId == nzoID }) else {
                throw BackendError.notFound
            }
            guard slot.isCompleted else { return slot.libraryItem() }
            return slot.libraryItem(files: try await files(under: slot.folderPath))
        case .folder(let path):
            let files = try await files(under: path)
            return LibraryItem(
                id: itemID,
                backend: .nzbdav,
                name: (path as NSString).lastPathComponent,
                size: files.compactMap(\.size).reduce(0, +),
                status: .ready,
                files: files
            )
        case nil:
            throw BackendError.notFound
        }
    }

    private func files(under folder: String) async throws -> [LibraryFile] {
        try await webDAV.files(under: folder).map { file in
            LibraryFile(id: file.path, name: String(file.path.dropFirst(folder.count + 1)), size: file.size)
        }
    }

    public func delete(_ itemID: LibraryItem.ID) async throws {
        switch NzbdavItemRef(itemID) {
        case .job(let nzoID):
            if try await queue().contains(where: { $0.nzoId == nzoID }) {
                _ = try await call("queue", [("name", "delete"), ("value", nzoID)], as: NzbdavStatus.self)
            } else {
                _ = try await call(
                    "history",
                    [("name", "delete"), ("value", nzoID), ("del_completed_files", "1")],
                    as: NzbdavStatus.self
                )
            }
        case .folder(let path):
            // Only a job folder (`/content/{category}/{job}`): never a category, never a way out of `/content`.
            let parts = path.split(separator: "/")
            guard parts.count == 3, parts[0] == "content", !parts.contains("..") else { throw BackendError.notFound }
            do {
                try await webDAV.delete(path)
            } catch BackendError.http(status: 403) {
                throw BackendError.api(message: Self.readOnlyMessage)
            }
        case nil:
            throw BackendError.notFound
        }
    }

    static let readOnlyMessage =
        "nzbdav does not allow deleting over WebDAV. Turn off Settings → WebDAV → \"Enforce Read-Only\" in nzbdav, then delete again."

    /// File IDs are WebDAV paths, so no lookup is needed.
    public func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
        guard fileID.hasPrefix(Self.contentRoot + "/") else { throw BackendError.notFound }
        var request = URLRequest(url: webDAV.url(for: fileID))
        request.setValue(webDAV.authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - API

    private func queue() async throws -> [NzbdavQueueSlot] {
        try await call("queue", [], as: NzbdavQueueResponse.self).queue?.slots ?? []
    }

    private func history(ids: [String] = []) async throws -> [NzbdavHistorySlot] {
        var fields = [("limit", "1000")]
        if !ids.isEmpty { fields.append(("nzo_ids", ids.joined(separator: ","))) }
        return try await call("history", fields, as: NzbdavHistoryResponse.self).history?.slots ?? []
    }

    /// Every job folder under `/content/{category}/`: one listing for the categories, one per category.
    /// A category that fails to list is skipped; the history still shows its jobs.
    private func jobFolders() async -> [WebDAVEntry] {
        guard let categories = try? await webDAV.list(Self.contentRoot) else { return [] }
        return await withTaskGroup(of: [WebDAVEntry].self) { group in
            for category in categories where category.isDirectory {
                group.addTask { (try? await webDAV.list(category.path))?.filter(\.isDirectory) ?? [] }
            }
            var folders: [WebDAVEntry] = []
            for await batch in group { folders += batch }
            return folders.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }
    }

    private func query(_ mode: String, _ fields: [(String, String)]) -> [URLQueryItem] {
        ([("mode", mode), ("output", "json")] + fields).map { URLQueryItem(name: $0.0, value: $0.1) }
    }

    private func call<T: Decodable>(_ mode: String, _ fields: [(String, String)], as type: T.Type) async throws -> T {
        try await decode(type, from: apiRequest(
            query: query(mode, fields),
            body: FormURLEncoded.encode([("apikey", apiKey)]),
            contentType: FormURLEncoded.contentType
        ))
    }

    private func apiRequest(query: [URLQueryItem], body: Data, contentType: String) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: "api"), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        // `URLQueryItem` leaves `&`, `=` and `+` inside values alone; an NZB link is full of them.
        components.percentEncodedQuery = query
            .map { "\($0.name)=\(($0.value ?? "").addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? "")" }
            .joined(separator: "&")
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return request
    }

    private func decode<T: Decodable>(_ type: T.Type, from request: URLRequest) async throws -> T {
        let (data, response) = try await transport.send(request)
        let status = try? Self.decoder.decode(NzbdavStatus.self, from: data)
        if status?.status == false || response.backendError != nil {
            if let message = status?.error, !message.isEmpty {
                throw message.localizedCaseInsensitiveContains("api key")
                    ? BackendError.unauthorized
                    : BackendError.api(message: message)
            }
            throw response.backendError ?? BackendError.invalidResponse
        }
        do {
            return try Self.decoder.decode(type, from: data)
        } catch {
            throw BackendError.invalidResponse
        }
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

extension NzbdavBackend: PlaybackLinking {
    /// The WebDAV URL with the login in it, for players that cannot send headers (Infuse).
    public func playbackURL(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URL {
        let request = try await downloadRequest(itemID: itemID, fileID: fileID)
        guard var components = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            throw BackendError.invalidResponse
        }
        components.user = webDAV.user
        components.password = webDAV.password
        guard let url = components.url else { throw BackendError.invalidResponse }
        return url
    }
}
