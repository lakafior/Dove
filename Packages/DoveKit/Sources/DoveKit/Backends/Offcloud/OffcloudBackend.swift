import Foundation

/// Offcloud adapter. Follows the API docs Offcloud published after its 2026-10 rebuild (offcloud.com/api, shown
/// only when logged in; the GitHub repo is outdated, its `remote` endpoints are gone). Older behaviour notes come
/// from Debrid Media Manager (`src/services/offcloud.ts`).
///
/// - Auth: `Authorization: Bearer <key>`. `?key=` / `?apiKey=` are legacy, and query strings end up in logs.
/// - Add magnet, torrent URL, hoster or NZB link: `POST /cloud` with JSON `{"url": …}`; `.torrent`/`.nzb` bytes as
///   multipart `file`. NZBs only with `usenet` on (Settings › Usenet › Offcloud Usenet).
///   A cached magnet answers `status: "downloaded"` at once. Offcloud accepts invalid magnets and never finishes
///   them, so the info hash is validated first.
/// - List: `GET /cloud/history` (active transfers; `progress` 0…1 and `message`, no sizes). Account: `GET /account/info`.
/// - Files: `GET /cloud/explore/{id}?format=detailed` (`path`, `size`, `url` per file; "Bad archive" for a single
///   file, which lives at `https://{server}.offcloud.com/cloud/download/{id}/{fileName}`, or comes from
///   `POST /cache/download` when the history has no `server`).
/// - Delete: `POST /cloud/remove` with `{"requests": [id]}`.
/// - Cache: `POST /cache/info` with `{"urls": [magnet…]}`, answered in the same order.
/// - Errors: `{"error": "…"}` (`NOAUTH` for any key problem); unknown paths answer with HTML, so check the content type.
public struct OffcloudBackend: LibraryBackend {
    public let id: BackendID = .offcloud
    public let supportedSources: Set<SourceKind>

    private let apiKey: String
    private let usenet: Bool
    private let transport: any HTTPTransport
    private let baseURL: URL

    public init(
        apiKey: String,
        usenet: Bool = false,
        transport: any HTTPTransport = URLSession.shared,
        baseURL: URL = URL(string: "https://offcloud.com/api")!
    ) {
        self.apiKey = apiKey
        self.usenet = usenet
        self.transport = transport
        self.baseURL = baseURL
        supportedSources = usenet ? [.torrent, .hoster, .nzb] : [.torrent, .hoster]
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
        try refusePrivateTorrent(source)
        let request: URLRequest
        switch source {
        case .magnet(let magnet):
            guard OffcloudMagnet.hasValidInfoHash(magnet) else {
                throw BackendError.api(message: "This magnet has no valid info hash.")
            }
            request = jsonRequest("cloud", body: ["url": magnet])
        case .torrentURL(let url):
            request = jsonRequest("cloud", body: ["url": url.absoluteString])
        case .hosterURL(let url, let password):
            // The cloud API has no password field.
            if let password, !password.isEmpty {
                throw BackendError.api(message: "Offcloud cannot open password-protected links.")
            }
            request = jsonRequest("cloud", body: ["url": url.absoluteString])
        case .torrentFile(let data, let filename):
            request = fileRequest(data, filename: filename, mimeType: "application/x-bittorrent")
        case .nzbURL(let url):
            guard usenet else { throw BackendError.unsupportedSource(.nzb) }
            request = jsonRequest("cloud", body: ["url": url.absoluteString])
        case .nzbFile(let data, let filename):
            guard usenet else { throw BackendError.unsupportedSource(.nzb) }
            request = fileRequest(data, filename: filename, mimeType: "application/x-nzb")
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
        return entry.libraryItem(files: Self.libraryFiles(try await files(for: entry)))
    }

    public func delete(_ itemID: LibraryItem.ID) async throws {
        guard let ref = OffcloudItemRef(itemID) else { throw BackendError.notFound }
        let result = try await decode(OffcloudRemoveResult.self, from: jsonRequest("cloud/remove", body: ["requests": [ref.requestID]]))
        if result.success == false { throw BackendError.api(message: "Offcloud did not remove this download.") }
    }

    public func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
        let files = try await files(for: historyEntry(itemID))
        guard let index = Int(fileID), files.indices.contains(index), let url = URL(string: files[index].url) else {
            throw BackendError.notFound
        }
        return URLRequest(url: url)
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

    /// Every file of a request, in a stable order (file IDs are indexes into it).
    private func files(for entry: OffcloudHistoryItem) async throws -> [OffcloudFile] {
        if entry.isDirectory != false {
            do {
                let explore = request(
                    "cloud/explore/\(entry.requestId)",
                    query: [URLQueryItem(name: "format", value: "detailed")]
                )
                return try await decode(OffcloudExplore.self, from: explore).files
            } catch BackendError.api(let message) {
                // Explore answers "Bad archive" for a single file.
                guard entry.isDirectory == nil else { throw BackendError.api(message: message) }
            }
        }
        if let url = entry.singleFileURL {
            return [OffcloudFile(url: url.absoluteString, path: nil, folder: nil, filename: entry.fileName, size: nil)]
        }
        // A finished torrent is cached, so Offcloud hands out its links without a server name.
        guard let hash = entry.infoHash else { throw BackendError.invalidResponse }
        return try await decode(
            [OffcloudFile].self,
            from: jsonRequest("cache/download", body: ["url": "magnet:?xt=urn:btih:\(hash)"])
        )
    }

    /// Paths without the download's own root folder (when every file sits in it), like the other services.
    static func libraryFiles(_ files: [OffcloudFile]) -> [LibraryFile] {
        let paths = files.map { file in
            (file.relativePath ?? URL(string: file.url)?.lastPathComponent ?? file.url).split(separator: "/").map(String.init)
        }
        let roots = Set(paths.compactMap { $0.count > 1 ? $0[0] : nil })
        let dropRoot = roots.count == 1 && paths.allSatisfy { $0.count > 1 }
        return zip(files, paths).enumerated().map { index, pair in
            let components = dropRoot ? Array(pair.1.dropFirst()) : pair.1
            return LibraryFile(id: String(index), name: components.joined(separator: "/"), size: pair.0.size)
        }
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

    private func fileRequest(_ data: Data, filename: String, mimeType: String) -> URLRequest {
        var form = MultipartFormData()
        form.addFile("file", filename: filename, mimeType: mimeType, data: data)
        return request("cloud", method: "POST", body: form.finalized(), contentType: form.contentType)
    }

    fileprivate func jsonRequest(_ path: String, body: [String: Any]) -> URLRequest {
        let data = try? JSONSerialization.data(withJSONObject: body)
        return request(path, method: "POST", body: data, contentType: "application/json")
    }

    fileprivate func request(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil
    ) -> URLRequest {
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
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

    fileprivate func decode<T: Decodable>(_ type: T.Type, from request: URLRequest) async throws -> T {
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

extension OffcloudBackend: CacheChecking {
    /// `POST /cache/info` with `{"urls": [magnet…]}` answers `[{"cached": Bool}]` in the same order. Adds nothing.
    public func cachedHashes(_ hashes: [String]) async throws -> Set<String> {
        var cached = Set<String>()
        for chunk in BackendID.chunks(hashes.map { $0.lowercased() }, of: 100) {
            let magnets = chunk.map { "magnet:?xt=urn:btih:\($0)" }
            let answers = try await decode([OffcloudCacheInfo].self, from: jsonRequest("cache/info", body: ["urls": magnets]))
            guard answers.count == chunk.count else { throw BackendError.invalidResponse }
            for (hash, answer) in zip(chunk, answers) where answer.cached == true { cached.insert(hash) }
        }
        return cached
    }
}

extension OffcloudBackend: AccountReporting {
    /// `GET account/info`: `is_premium` and `expiration_date`.
    public func account() async throws -> AccountStatus {
        let info = try await decode(OffcloudAccountInfo.self, from: request("account/info"))
        let isPremium = info.isPremium ?? false
        return AccountStatus(isPremium: isPremium, premiumUntil: isPremium ? AccountDate.parse(info.expirationDate) : nil)
    }
}
