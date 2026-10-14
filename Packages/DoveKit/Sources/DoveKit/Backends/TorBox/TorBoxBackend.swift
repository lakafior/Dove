import Foundation

/// TorBox adapter. API docs: https://api-docs.torbox.app
///
/// Auth: `Authorization: Bearer <key>` on every call, except `requestdl`, which takes `token=<key>` as a query item.
/// Torrents, hoster links ("web downloads") and NZBs ("usenet") live in separate endpoints with the same shape;
/// this adapter merges them into one library. Usenet needs a paid plan, so it is off unless the user turns it on:
/// otherwise every NZB would first fail here. Usenet endpoints follow the official SDK (`usenet/createusenetdownload`
/// with `link` or `file`, `usenet/mylist`, `usenet/requestdl?usenet_id=`, `usenet/controlusenetdownload`).
///
/// Paid plans seed finished torrents for a while (`TorBoxPlan.seedingTime`), so private trackers' torrents may go
/// here when the user allows it (`takesPrivateTorrents`). Those are added with `seed=2` (from the SDK: 1 auto =
/// the account's setting, 2 seed, 3 don't seed); everything else keeps the account's setting.
/// `mylist` reports `ratio`, `upload_speed`, `peers` and the state ("uploading" while seeding).
public struct TorBoxBackend: LibraryBackend {
    public let id: BackendID = .torBox
    public let supportedSources: Set<SourceKind>
    public let takesPrivateTorrents: Bool

    private let apiKey: String
    private let usenet: Bool
    private let transport: any HTTPTransport
    private let baseURL: URL

    public init(
        apiKey: String,
        usenet: Bool = false,
        takesPrivateTorrents: Bool = false,
        transport: any HTTPTransport = URLSession.shared,
        baseURL: URL = URL(string: "https://api.torbox.app/v1/api")!
    ) {
        self.apiKey = apiKey
        self.usenet = usenet
        self.takesPrivateTorrents = takesPrivateTorrents
        self.transport = transport
        self.baseURL = baseURL
        supportedSources = usenet ? [.torrent, .hoster, .nzb] : [.torrent, .hoster]
    }

    // MARK: - LibraryBackend

    public func validateCredentials() async throws {
        _ = try await perform(request("user/me"), as: TorBoxIgnored.self)
    }

    @discardableResult
    public func add(_ source: Source) async throws -> LibraryItem.ID {
        try await add(source, category: nil, privateTracker: false)
    }

    @discardableResult
    public func add(_ source: Source, category: AddCategory?, privateTracker: Bool) async throws -> LibraryItem.ID {
        try refusePrivateTorrent(source)
        if privateTracker, !takesPrivateTorrents { throw BackendError.privateTorrent }
        let seed = privateTracker || source.isPrivateTorrent
        switch source {
        case .magnet(let magnet):
            var form = MultipartFormData()
            form.addField("magnet", magnet)
            return try await createTorrent(form, seed: seed)

        case .torrentFile(let data, let filename):
            var form = MultipartFormData()
            form.addFile("file", filename: filename, mimeType: "application/x-bittorrent", data: data)
            return try await createTorrent(form, seed: seed)

        case .torrentURL(let url):
            // TorBox wants the file itself, so fetch it first.
            let (data, response) = try await transport.send(URLRequest(url: url))
            if let error = response.backendError { throw error }
            let filename = url.lastPathComponent.isEmpty ? "download.torrent" : url.lastPathComponent
            return try await add(.torrentFile(data: data, filename: filename), category: category, privateTracker: privateTracker)

        case .hosterURL(let url, let password):
            var form = MultipartFormData()
            form.addField("link", url.absoluteString)
            if let password, !password.isEmpty { form.addField("password", password) }
            let result = try await perform(
                request("webdl/createwebdownload", method: "POST", body: form.finalized(), contentType: form.contentType),
                as: TorBoxCreateResult.self
            )
            if let id = result?.webdownloadId { return TorBoxItemRef.webDownload(id).id }
            if let id = result?.queuedId { return TorBoxItemRef.queued(id).id }
            throw BackendError.invalidResponse

        case .nzbURL(let url):
            guard usenet else { throw BackendError.unsupportedSource(.nzb) }
            var form = MultipartFormData()
            form.addField("link", url.absoluteString)
            return try await createUsenet(form)

        case .nzbFile(let data, let filename):
            guard usenet else { throw BackendError.unsupportedSource(.nzb) }
            var form = MultipartFormData()
            form.addFile("file", filename: filename, mimeType: "application/x-nzb", data: data)
            return try await createUsenet(form)
        }
    }

    public func items() async throws -> [LibraryItem] {
        let bypass = [URLQueryItem(name: "bypass_cache", value: "true")]
        async let torrents = perform(request("torrents/mylist", query: bypass), as: [TorBoxTransfer].self)
        async let webDownloads = perform(request("webdl/mylist", query: bypass), as: [TorBoxTransfer].self)

        let torrentItems = (try await torrents ?? []).map { $0.libraryItem(ref: .torrent($0.id)) }
        let webItems = (try await webDownloads ?? []).map { $0.libraryItem(ref: .webDownload($0.id)) }
        let usenetItems = usenet
            ? (try await perform(request("usenet/mylist", query: bypass), as: [TorBoxTransfer].self) ?? [])
                .map { $0.libraryItem(ref: .usenet($0.id)) }
            : []

        return (torrentItems + webItems + usenetItems).sorted {
            ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast)
        }
    }

    public func delete(_ itemID: LibraryItem.ID) async throws {
        guard let ref = TorBoxItemRef(itemID) else { throw BackendError.notFound }
        let (path, body): (String, [String: Any]) = switch ref {
        case .torrent(let id): ("torrents/controltorrent", ["torrent_id": id, "operation": "delete"])
        case .webDownload(let id): ("webdl/controlwebdownload", ["webdl_id": id, "operation": "delete"])
        case .queued(let id): ("queued/controlqueued", ["queued_id": id, "operation": "delete"])
        case .usenet(let id): ("usenet/controlusenetdownload", ["usenet_id": id, "operation": "delete"])
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
        case .usenet(let id): ("usenet/requestdl", "usenet_id", id)
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

    /// Hashes per `checkcached` call; they go in the query string.
    static let cacheCheckChunk = 100

    /// `seed`: ask TorBox to seed this one whatever the account's setting says (private trackers).
    private func createTorrent(_ form: MultipartFormData, seed: Bool) async throws -> LibraryItem.ID {
        var form = form
        if seed { form.addField("seed", "2") }
        let result = try await perform(
            request("torrents/createtorrent", method: "POST", body: form.finalized(), contentType: form.contentType),
            as: TorBoxCreateResult.self
        )
        if let id = result?.torrentId { return TorBoxItemRef.torrent(id).id }
        if let id = result?.queuedId { return TorBoxItemRef.queued(id).id }
        throw BackendError.invalidResponse
    }

    private func createUsenet(_ form: MultipartFormData) async throws -> LibraryItem.ID {
        let result = try await perform(
            request("usenet/createusenetdownload", method: "POST", body: form.finalized(), contentType: form.contentType),
            as: TorBoxCreateResult.self
        )
        if let id = result?.usenetdownloadId?.value { return TorBoxItemRef.usenet(id).id }
        if let id = result?.queuedId { return TorBoxItemRef.queued(id).id }
        throw BackendError.invalidResponse
    }

    fileprivate func request(
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
    fileprivate func perform<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T? {
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

extension TorBoxBackend: CacheChecking {
    /// `GET torrents/checkcached?hash=a,b&format=list` answers with the cached ones only. Adds nothing, costs nothing.
    public func cachedHashes(_ hashes: [String]) async throws -> Set<String> {
        var cached = Set<String>()
        for chunk in BackendID.chunks(hashes.map { $0.lowercased() }, of: Self.cacheCheckChunk) {
            let query = [
                URLQueryItem(name: "hash", value: chunk.joined(separator: ",")),
                URLQueryItem(name: "format", value: "list"),
                URLQueryItem(name: "list_files", value: "false")
            ]
            let items = try await perform(request("torrents/checkcached", query: query), as: [TorBoxCachedItem].self) ?? []
            cached.formUnion(items.compactMap { $0.hash?.lowercased() })
        }
        return cached
    }
}

extension TorBoxBackend: AccountReporting {
    /// `GET user/me`: `plan` 0 free, 1 Essential, 2 Pro, 3 Standard (`TorBoxPlan`); `premium_expires_at` (ISO 8601).
    public func account() async throws -> AccountStatus {
        guard let user = try await perform(request("user/me"), as: TorBoxUser.self) else { throw BackendError.invalidResponse }
        let plan = user.plan.flatMap(TorBoxPlan.init(rawValue:)) ?? .free
        let isPremium = plan != .free
        return AccountStatus(
            isPremium: isPremium,
            premiumUntil: isPremium ? AccountDate.parse(user.premiumExpiresAt) : nil,
            plan: isPremium ? plan.name : nil
        )
    }
}

struct TorBoxUser: Decodable {
    let plan: Int?
    let premiumExpiresAt: String?
}

extension TorBoxBackend: HosterListing {
    /// `GET webdl/hosters`: domains, `status` (false while down) and the account's daily link usage.
    public func hostList() async throws -> HostList {
        let hosters = try await perform(request("webdl/hosters"), as: [TorBoxHoster].self) ?? []
        return HostList(hosts: hosters.map { hoster in
            let left = hoster.dailyLinkLimit.flatMap { limit in
                limit > 0 ? max(0, limit - (hoster.dailyLinkUsed ?? 0)) : nil
            }
            return HostList.Host(name: hoster.name, domains: hoster.domains ?? [], online: hoster.status, linksLeft: left)
        })
    }
}

/// Entry of `GET webdl/hosters`. A daily link limit of 0 means none.
struct TorBoxHoster: Decodable {
    let name: String
    let domains: [String]?
    let status: Bool?
    let dailyLinkLimit: Int?
    let dailyLinkUsed: Int?
}
