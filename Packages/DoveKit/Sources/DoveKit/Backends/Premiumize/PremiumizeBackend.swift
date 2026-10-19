import Foundation

/// Premiumize adapter (premiumize.me/api). A cloud like Offcloud: transfers fetch torrents, hoster links and NZBs
/// into the user's cloud, where they stay as folders and files.
///
/// - Auth: `Authorization: Bearer <key>` (the `apikey` parameter is legacy and would put the key in URLs).
/// - Add: `POST transfer/create` with `src` (magnet, link or NZB link) or a multipart `src` file, and `password` for
///   protected hoster links. Answers `id`. NZBs only with `usenet` on (Settings › Usenet › Premiumize Usenet).
/// - Library: unfinished transfers (`GET transfer/list`: `status` queued/waiting/running/finished/seeding/error/
///   timeout/banned/deleted, `progress` 0…1, `message`) plus the cloud's root (`GET folder/list`). A finished
///   transfer points at its own folder (`folder_id`) or file (`file_id`), which the root then lists, so finished
///   transfers are not listed twice.
/// - Files: `folder/list?id=` walked recursively; a file's link from `item/details?id=` (`link`, no auth needed).
/// - Delete: `transfer/delete`, `folder/delete`, `item/delete` (form `id`). Deleting a finished transfer deletes
///   what it put in the cloud too.
/// - Cache: `GET cache/check?items[]=` answers `response` booleans in order. Hosters: `GET services/list`.
/// - Errors: `{"status": "error", "message", "code"}`, usually with HTTP 200 (`authentication_failed`,
///   `rate_limit_reached`, `service_unsupported`…).
public struct PremiumizeBackend: LibraryBackend {
    public let id: BackendID = .premiumize
    public let supportedSources: Set<SourceKind>
    public var acceptsDirectLinks: Bool { true }

    private let apiKey: String
    private let usenet: Bool
    private let transport: any HTTPTransport
    private let baseURL: URL
    /// Folders below an item that are walked for its files.
    static let maxDepth = 8

    public init(
        apiKey: String,
        usenet: Bool = true,
        transport: any HTTPTransport = URLSession.shared,
        baseURL: URL = URL(string: "https://www.premiumize.me/api")!
    ) {
        self.apiKey = apiKey
        self.usenet = usenet
        self.transport = transport
        self.baseURL = baseURL
        supportedSources = usenet ? [.torrent, .hoster, .nzb] : [.torrent, .hoster]
    }

    // MARK: - LibraryBackend

    public func validateCredentials() async throws {
        let account = try await decode(PremiumizeAccount.self, from: request("account/info"))
        guard (account.premiumUntil ?? 0) > Int64(Date.now.timeIntervalSince1970) else {
            throw BackendError.api(message: "This Premiumize account is not premium.")
        }
    }

    @discardableResult
    public func add(_ source: Source) async throws -> LibraryItem.ID {
        try refusePrivateTorrent(source)
        var form: [(String, String)] = []
        switch source {
        case .magnet(let magnet):
            form = [("src", magnet)]
        case .torrentURL(let url):
            form = [("src", url.absoluteString)]
        case .hosterURL(let url, let password):
            form = [("src", url.absoluteString)]
            if let password, !password.isEmpty { form.append(("password", password)) }
        case .nzbURL(let url, _):
            guard usenet else { throw BackendError.unsupportedSource(.nzb) }
            form = [("src", url.absoluteString)]
        case .torrentFile(let data, let filename):
            return try await create(file: data, filename: filename, mimeType: "application/x-bittorrent")
        case .nzbFile(let data, let filename):
            guard usenet else { throw BackendError.unsupportedSource(.nzb) }
            return try await create(file: data, filename: filename, mimeType: "application/x-nzb")
        }
        return try await created(request("transfer/create", method: "POST", form: form))
    }

    public func items() async throws -> [LibraryItem] {
        async let transfers = transferList()
        async let root = decode(PremiumizeFolder.self, from: request("folder/list"))
        let active = try await transfers.filter { !$0.isFinished }.map { $0.libraryItem() }
        let cloud = try await root.content.map(Self.libraryItem)
        return active + cloud.sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
    }

    public func item(_ itemID: LibraryItem.ID) async throws -> LibraryItem {
        switch PremiumizeItemRef(itemID) {
        case .transfer(let id):
            guard let transfer = try await transferList().first(where: { $0.id == id }) else { throw BackendError.notFound }
            guard transfer.isFinished else { return transfer.libraryItem() }
            if let folder = transfer.folderId, !folder.isEmpty {
                return transfer.libraryItem(files: try await files(inFolder: folder))
            }
            if let file = transfer.fileId, !file.isEmpty {
                let details = try await details(file)
                return transfer.libraryItem(files: [LibraryFile(id: details.id, name: details.name ?? transfer.name ?? details.id, size: details.size)])
            }
            return transfer.libraryItem()
        case .folder(let id):
            let folder = try await folder(id)
            let files = try await files(in: folder)
            let name = folder.name ?? id
            return LibraryItem(
                id: itemID, backend: .premiumize, name: name,
                size: files.compactMap(\.size).reduce(0, +), status: .ready, files: files
            )
        case .file(let id):
            let details = try await details(id)
            let name = details.name ?? id
            return LibraryItem(
                id: itemID, backend: .premiumize, name: name, size: details.size, status: .ready,
                files: [LibraryFile(id: details.id, name: name, size: details.size)]
            )
        case nil:
            throw BackendError.notFound
        }
    }

    public func delete(_ itemID: LibraryItem.ID) async throws {
        switch PremiumizeItemRef(itemID) {
        case .transfer(let id):
            // A finished transfer's folder or file is what the user sees; remove it with the transfer.
            if let transfer = try await transferList().first(where: { $0.id == id }), transfer.isFinished {
                if let folder = transfer.folderId, !folder.isEmpty {
                    try await perform(request("folder/delete", method: "POST", form: [("id", folder)]))
                } else if let file = transfer.fileId, !file.isEmpty {
                    try await perform(request("item/delete", method: "POST", form: [("id", file)]))
                }
            }
            try await perform(request("transfer/delete", method: "POST", form: [("id", id)]))
        case .folder(let id):
            try await perform(request("folder/delete", method: "POST", form: [("id", id)]))
        case .file(let id):
            try await perform(request("item/delete", method: "POST", form: [("id", id)]))
        case nil:
            throw BackendError.notFound
        }
    }

    public func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
        guard let link = try await details(fileID).link, let url = URL(string: link) else { throw BackendError.notFound }
        return URLRequest(url: url)
    }

    // MARK: - Helpers

    private func transferList() async throws -> [PremiumizeTransfer] {
        try await decode(PremiumizeTransferList.self, from: request("transfer/list")).transfers
    }

    private func details(_ fileID: String) async throws -> PremiumizeItemDetails {
        try await decode(PremiumizeItemDetails.self, from: request("item/details", query: [URLQueryItem(name: "id", value: fileID)]))
    }

    private func folder(_ id: String) async throws -> PremiumizeFolder {
        try await decode(PremiumizeFolder.self, from: request("folder/list", query: [URLQueryItem(name: "id", value: id)]))
    }

    private func files(inFolder id: String) async throws -> [LibraryFile] {
        try await files(in: folder(id))
    }

    /// Every file under a folder, paths relative to it, in name order per folder.
    private func files(in folder: PremiumizeFolder, prefix: String = "", depth: Int = 0) async throws -> [LibraryFile] {
        var result: [LibraryFile] = []
        for entry in folder.content.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            if entry.isFolder {
                guard depth < Self.maxDepth else { continue }
                result += try await files(in: self.folder(entry.id), prefix: prefix + entry.name + "/", depth: depth + 1)
            } else {
                result.append(LibraryFile(id: entry.id, name: prefix + entry.name, size: entry.size))
            }
        }
        return result
    }

    static func libraryItem(_ entry: PremiumizeFolderItem) -> LibraryItem {
        if entry.isFolder {
            return LibraryItem(id: PremiumizeItemRef.folder(entry.id).id, backend: .premiumize, name: entry.name, status: .ready, addedAt: entry.addedAt)
        }
        return LibraryItem(
            id: PremiumizeItemRef.file(entry.id).id, backend: .premiumize, name: entry.name, size: entry.size,
            status: .ready, files: [LibraryFile(id: entry.id, name: entry.name, size: entry.size)], addedAt: entry.addedAt
        )
    }

    private func create(file data: Data, filename: String, mimeType: String) async throws -> LibraryItem.ID {
        var form = MultipartFormData()
        form.addFile("src", filename: filename, mimeType: mimeType, data: data)
        return try await created(request("transfer/create", method: "POST", body: form.finalized(), contentType: form.contentType))
    }

    private func created(_ request: URLRequest) async throws -> LibraryItem.ID {
        guard let id = try await decode(PremiumizeCreated.self, from: request).id, !id.isEmpty else {
            throw BackendError.invalidResponse
        }
        return PremiumizeItemRef.transfer(id).id
    }

    fileprivate func request(
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
        request.timeoutInterval = 30
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

    /// Sends the request and maps failures from the envelope (usually HTTP 200) or the status code.
    @discardableResult
    fileprivate func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.send(request)
        if let envelope = try? Self.decoder.decode(PremiumizeEnvelope.self, from: data), envelope.status == "error" {
            throw Self.error(code: envelope.code, message: envelope.message)
        }
        if let error = response.backendError { throw error }
        return data
    }

    fileprivate func decode<T: Decodable>(_ type: T.Type, from request: URLRequest) async throws -> T {
        let data = try await perform(request)
        do {
            return try Self.decoder.decode(type, from: data)
        } catch {
            throw BackendError.invalidResponse
        }
    }

    static func error(code: String?, message: String?) -> BackendError {
        switch code {
        case "authentication_failed": return .unauthorized
        case "rate_limit_reached": return .rateLimited
        case "not_found": return .notFound
        case "service_unsupported": return .api(message: "Premiumize does not support this site.")
        case "service_limit_reached", "account_limit_reached":
            return .api(message: "Premiumize's limit is reached\(message.map { ": \($0)" } ?? ".")")
        default:
            guard let message, !message.isEmpty else { return .api(message: "Premiumize request failed.") }
            // Older answers carry only a message.
            if message.lowercased().contains("auth") || message.lowercased().contains("api key") { return .unauthorized }
            return .api(message: "Premiumize: \(message)")
        }
    }

    fileprivate static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

extension PremiumizeBackend: CacheChecking {
    /// `GET cache/check?items[]=magnet…`: booleans in the order asked. Adds nothing.
    public func cachedHashes(_ hashes: [String]) async throws -> Set<String> {
        var cached = Set<String>()
        for chunk in BackendID.chunks(hashes.map { $0.lowercased() }, of: 100) {
            let query = chunk.map { URLQueryItem(name: "items[]", value: "magnet:?xt=urn:btih:\($0)") }
            let answer = try await decode(PremiumizeCacheCheck.self, from: request("cache/check", query: query))
            guard answer.response.count == chunk.count else { throw BackendError.invalidResponse }
            for (hash, isCached) in zip(chunk, answer.response) where isCached { cached.insert(hash) }
        }
        return cached
    }
}

extension PremiumizeBackend: AccountReporting {
    /// `GET account/info`: `premium_until` in Unix seconds.
    public func account() async throws -> AccountStatus {
        let account = try await decode(PremiumizeAccount.self, from: request("account/info"))
        let until = account.premiumUntil.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        return AccountStatus(isPremium: (until ?? .distantPast) > .now, premiumUntil: until)
    }
}

extension PremiumizeBackend: HosterListing {
    /// `GET services/list`: `directdl` domains, each with its `aliases`. Premiumize does not say which are down.
    public func hostList() async throws -> HostList {
        let services = try await decode(PremiumizeServices.self, from: request("services/list"))
        return HostList(hosts: (services.directdl ?? []).map { domain in
            HostList.Host(name: domain, domains: [domain] + (services.aliases?[domain] ?? []))
        })
    }
}
