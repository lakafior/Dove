import CryptoKit
import Foundation

/// nzbdav adapter. nzbdav emulates the SABnzbd API and mounts finished jobs over WebDAV.
/// Source: https://github.com/nzbdav-dev/nzbdav (behaviour below checked against its controllers), and its
/// maintained fork InfiniDysk (https://github.com/infinidysk/infinidysk, same API and `/config`; checked 1.6.1).
/// Differences Dove uses, each with a fallback for nzbdav: InfiniDysk takes the SABnzbd key on
/// `/api/download-nzb`, has `mode=retry`, sends `completed` (unix seconds) in history, and signs `/view`
/// links with HMAC-SHA256 (it still accepts nzbdav's `sha256("{path}_{key}")`).
///
/// - API: `POST {base}/api?mode=…&output=json&…` with the API key alone in a form body, so it stays out of URLs
///   and server logs. The other parameters must be in the query: nzbdav reads `addurl`'s `name` and the
///   delete `value`s only from there (checked live: in the body they arrive empty, and a delete "succeeds"
///   without deleting). The NZB link therefore lands in the query, as with Sonarr and Radarr.
///   Errors are `{"status": false, "error": "…"}`, 401 for a wrong key.
/// - Add: `mode=addurl` (`name` = NZB link, nzbdav fetches it) or `mode=addfile` (multipart `nzbFile`), with
///   `cat` (`AddCategory`: the caller's, else guessed from the NZB's file name). Without one the job goes to the
///   manual-upload category (`uncategorized`); nzbdav makes a folder for any category it is sent. Answer: `nzo_ids`.
/// - List: `mode=queue` (in progress), `mode=history` (`Completed` / `Failed` with `fail_message`), and every job
///   folder under `/content/{category}/`. nzbdav keeps a job's files after its history entry is cleared
///   (without "delete files", or by another client), so the folders are the real library: a folder without a
///   history entry is listed as its own item (`dav:` ID). History has no dates; folder modification times do.
/// - Files: WebDAV `PROPFIND` under `/content/{category}/{job name}/`, Basic Auth. The category must match
///   the history's spelling (`Tv` and `TV` can both exist). `href`s carry the server's internal host.
/// - Download: `GET` the WebDAV path with Basic Auth (ranges work). Infuse gets a signed
///   `/view/{path}?downloadKey=sha256("{path}_{key}")` link when the frontend key is set (no login in the link),
///   otherwise the WebDAV URL with the credentials in it.
/// - Frontend key: the `FRONTEND_BACKEND_API_KEY` environment variable (random on every start unless the
///   user sets it). It signs `/view` links. `GET /api/download-nzb?nzbBlobId=` (header `x-api-key`), the NZB
///   stored for every history entry, takes it too; InfiniDysk also takes the SABnzbd key there, nzbdav does not.
/// - Delete: `mode=queue&name=delete` or `mode=history&name=delete&del_completed_files=1`; a folder without a
///   history entry with WebDAV `DELETE`, which nzbdav refuses (403) while "Enforce read-only" is on (its default).
public struct NzbdavBackend: LibraryBackend {
    public let id: BackendID = .nzbdav
    public let supportedSources: Set<SourceKind> = [.nzb]

    private let baseURL: URL
    private let apiKey: String
    private let webDAV: WebDAVClient
    private let transport: any HTTPTransport
    /// `FRONTEND_BACKEND_API_KEY`; nil when the user did not set it.
    private let frontendKey: String?

    static let contentRoot = "/content"

    public init(
        baseURL: URL,
        apiKey: String,
        webDAVUser: String,
        webDAVPassword: String,
        frontendKey: String? = nil,
        transport: any HTTPTransport = URLSession.shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.frontendKey = frontendKey.flatMap { $0.isEmpty ? nil : $0 }
        self.transport = transport
        webDAV = WebDAVClient(baseURL: baseURL, user: webDAVUser, password: webDAVPassword, transport: transport)
    }

    // MARK: - LibraryBackend

    /// Checks every secret: the API key (queue), the WebDAV login (root listing) and, when set, the frontend key.
    public func validateCredentials() async throws {
        _ = try await queue()
        _ = try await webDAV.list("/")
        if frontendKey != nil { try await validateFrontendKey() }
    }

    /// Asks for an NZB that cannot exist: a right key gets 400 ("not found"), a wrong one 401.
    func validateFrontendKey() async throws {
        do {
            _ = try await downloadNZB(blobID: "00000000-0000-0000-0000-000000000000")
        } catch BackendError.unauthorized {
            throw BackendError.api(message: Self.frontendKeyMessage)
        } catch BackendError.http(status: 400) {
            return
        } catch BackendError.api {
            return
        }
    }

    static let frontendKeyMessage =
        "nzbdav refused the frontend key. It must equal FRONTEND_BACKEND_API_KEY in nzbdav's environment (docker compose)."

    @discardableResult
    public func add(_ source: Source) async throws -> LibraryItem.ID {
        try await add(source, category: nil)
    }

    @discardableResult
    public func add(_ source: Source, category: AddCategory?) async throws -> LibraryItem.ID {
        let created: NzbdavAdded
        switch source {
        case .nzbURL(let url, let name):
            let cat = category.map { [("cat", $0.rawValue)] } ?? []
            // `nzbname` names the job (and its folder) after the indexer's title, not the NZB's file name.
            let jobName = name.map { [("nzbname", $0)] } ?? []
            created = try await call("addurl", [("name", url.absoluteString)] + jobName + cat, as: NzbdavAdded.self)
        case .nzbFile(let data, let filename):
            var form = MultipartFormData()
            form.addField("apikey", apiKey)
            form.addFile("nzbFile", filename: filename, mimeType: "application/x-nzb", data: data)
            let cat = (category ?? AddCategory(releaseName: filename)).map { [("cat", $0.rawValue)] } ?? []
            created = try await decode(NzbdavAdded.self, from: apiRequest(
                query: query("addfile", cat),
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

    enum ViewSigning {
        /// InfiniDysk: `HMAC-SHA256(key, path)`.
        case hmac
        /// nzbdav: `SHA256("{path}_{key}")`; InfiniDysk still accepts it.
        case legacy
    }

    /// `/view/{path}?downloadKey=…`: the server signs the decoded path without its leading slash.
    static func viewURL(base: URL, path: String, key: String, signing: ViewSigning) -> URL {
        let relative = String(path.drop { $0 == "/" })
        let digest: String = switch signing {
        case .hmac:
            HMAC<SHA256>.authenticationCode(for: Data(relative.utf8), using: SymmetricKey(data: Data(key.utf8)))
                .map { String(format: "%02x", $0) }.joined()
        case .legacy:
            SHA256.hash(data: Data("\(relative)_\(key)".utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let encodedPath = relative.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: unreserved) ?? String($0) }
            .joined(separator: "/")
        var components = URLComponents(url: base.appending(path: "view"), resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = components.percentEncodedPath + "/" + encodedPath
        components.queryItems = [URLQueryItem(name: "downloadKey", value: digest)]
        return components.url!
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

extension NzbdavBackend: NZBProviding {
    public func providesNZB(for item: LibraryItem) -> Bool {
        item.nzbBlobID != nil
    }

    /// The NZB nzbdav stored for this history entry.
    public func nzb(of item: LibraryItem) async throws -> Source {
        guard let blobID = item.nzbBlobID else {
            throw BackendError.api(message: "nzbdav has no NZB stored for this job.")
        }
        let (data, filename) = try await downloadNZB(blobID: blobID)
        return .nzbFile(data: data, filename: filename ?? Self.nzbFilename(for: item.name))
    }

    /// `GET /api/download-nzb` with the frontend key, or the SABnzbd key (InfiniDysk); the key goes in a header,
    /// never in the URL.
    func downloadNZB(blobID: String) async throws -> (Data, String?) {
        var components = URLComponents(url: baseURL.appending(path: "api/download-nzb"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "nzbBlobId", value: blobID)]
        var request = URLRequest(url: components.url!)
        request.setValue(frontendKey ?? apiKey, forHTTPHeaderField: "x-api-key")
        let (data, response) = try await transport.send(request)
        if response.statusCode == 401, frontendKey == nil {
            throw BackendError.api(message: Self.needsFrontendKeyMessage)
        }
        if let error = response.backendError {
            // `{"status": false, "error": "NZB not found."}` on 400.
            if error != .unauthorized, let message = (try? Self.decoder.decode(NzbdavStatus.self, from: data))?.error, !message.isEmpty {
                throw BackendError.api(message: "nzbdav: \(message)")
            }
            throw error
        }
        return (data, Self.filename(fromContentDisposition: response.value(forHTTPHeaderField: "Content-Disposition")))
    }

    static let needsFrontendKeyMessage =
        "This nzbdav only hands NZBs back with its frontend key: add it in Settings › nzbdav, or move to InfiniDysk, nzbdav's maintained fork."

    /// `mode=retry&value={nzo_id}` (InfiniDysk): the server re-queues a failed job from its stored NZB, in its
    /// category. nzbdav answers "Invalid mode", which gives nil.
    public func retry(_ item: LibraryItem) async throws -> LibraryItem.ID? {
        guard case .job(let nzoID) = NzbdavItemRef(item.id) else { return nil }
        do {
            let answer = try await call("retry", [("value", nzoID)], as: NzbdavRetried.self)
            guard let id = answer.nzoId ?? answer.nzoIds?.first else { throw BackendError.invalidResponse }
            return NzbdavItemRef(nzoID: id).id
        } catch BackendError.api(let message) where message.localizedCaseInsensitiveContains("invalid mode") {
            return nil
        }
    }

    static func nzbFilename(for name: String) -> String {
        name.lowercased().hasSuffix(".nzb") ? name : name + ".nzb"
    }

    /// `attachment; filename=x.nzb; filename*=UTF-8''x.nzb` (ASP.NET's `File(…, name)`).
    static func filename(fromContentDisposition header: String?) -> String? {
        guard let header else { return nil }
        let parts = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        if let encoded = parts.first(where: { $0.lowercased().hasPrefix("filename*=") }) {
            let value = encoded.dropFirst("filename*=".count)
            if let range = value.range(of: "''"), let decoded = String(value[range.upperBound...]).removingPercentEncoding {
                return decoded
            }
        }
        if let plain = parts.first(where: { $0.lowercased().hasPrefix("filename=") }) {
            let value = plain.dropFirst("filename=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

extension NzbdavBackend: PlaybackLinking {
    /// For players that cannot send headers (Infuse): a signed `/view` link with the frontend key, otherwise
    /// the WebDAV URL with the login in it.
    public func playbackURL(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URL {
        if let frontendKey {
            guard fileID.hasPrefix(Self.contentRoot + "/") else { throw BackendError.notFound }
            // InfiniDysk's HMAC key first; nzbdav only knows the older one, so one byte of the file decides.
            let signed = Self.viewURL(base: baseURL, path: fileID, key: frontendKey, signing: .hmac)
            var probe = URLRequest(url: signed)
            probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            if let (_, response) = try? await transport.send(probe), response.statusCode == 401 {
                return Self.viewURL(base: baseURL, path: fileID, key: frontendKey, signing: .legacy)
            }
            return signed
        }
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
