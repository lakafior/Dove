import Foundation

/// Debrid-Link adapter (API v2). Docs: https://debrid-link.com/api_doc/v2/introduction (rendered by script; the
/// same content is JSON at `api/v2/api_doc/infos` and `api/v2/api_doc/errors`).
///
/// Auth: the user's private API key as `Authorization: Bearer <key>` (OAuth would need a registered app).
/// Torrents live in the "seedbox" (`seedbox/add|list|<ids>/remove`), hoster links in the "downloader"
/// (`downloader/add|list|<ids>/remove`); this adapter merges both into one library.
///
/// Debrid-Link keeps seeding what it downloads, so private trackers' torrents may go here
/// (`takesPrivateTorrents`, `TorrentFile.isPrivate`) unless the user sends them only to TorBox.
///
/// - `seedbox/add` takes a magnet or hash (`url`, JSON) or a `.torrent` (`file`, multipart). A bare hash is
///   added only when Debrid-Link has it cached; torrent URLs must be public, so Dove fetches them and uploads
///   the file.
/// - Lists are paginated (`perPage` at most 100, `pagination.next` -1 on the last page).
/// - A torrent with many files lists one ZIP entry (`isZip`); `seedbox/list?ids=` lists the real files.
/// - Files carry their own `downloadUrl` (no auth needed), ready when `downloadPercent` is 100.
///   Downloader links expire (`expired`); adding the hoster URL again gives a fresh one.
public struct DebridLinkBackend: LibraryBackend {
    public let id: BackendID = .debridLink
    public let supportedSources: Set<SourceKind> = [.torrent, .hoster]
    public let takesPrivateTorrents: Bool

    private let apiKey: String
    private let transport: any HTTPTransport
    private let baseURL: URL

    public init(
        apiKey: String,
        takesPrivateTorrents: Bool = true,
        transport: any HTTPTransport = URLSession.shared,
        baseURL: URL = URL(string: "https://debrid-link.com/api/v2")!
    ) {
        self.apiKey = apiKey
        self.takesPrivateTorrents = takesPrivateTorrents
        self.transport = transport
        self.baseURL = baseURL
    }

    // MARK: - LibraryBackend

    public func validateCredentials() async throws {
        _ = try await perform(request("account/infos"), as: DebridLinkIgnored.self)
    }

    @discardableResult
    public func add(_ source: Source) async throws -> LibraryItem.ID {
        try refusePrivateTorrent(source)
        switch source {
        case .magnet(let magnet):
            let torrent = try await perform(jsonRequest("seedbox/add", body: ["url": magnet]), as: DebridLinkTorrent.self)
            return DebridLinkItemRef.torrent(torrent.id).id

        case .torrentFile(let data, let filename):
            var form = MultipartFormData()
            form.addFile("file", filename: filename, mimeType: "application/x-bittorrent", data: data)
            let torrent = try await perform(
                request("seedbox/add", method: "POST", body: form.finalized(), contentType: form.contentType),
                as: DebridLinkTorrent.self
            )
            return DebridLinkItemRef.torrent(torrent.id).id

        case .torrentURL(let url):
            // Debrid-Link only fetches public URLs; the phone may reach hosts it cannot.
            let (data, response) = try await transport.send(URLRequest(url: url))
            if let error = response.backendError { throw error }
            let filename = url.lastPathComponent.lowercased().hasSuffix(".torrent") ? url.lastPathComponent : "download.torrent"
            return try await add(.torrentFile(data: data, filename: filename))

        case .hosterURL(let url, let password):
            guard let link = try await addLink(url.absoluteString, password: password).first else { throw BackendError.invalidResponse }
            return DebridLinkItemRef.link(link.id).id

        case .nzbURL, .nzbFile:
            throw BackendError.unsupportedSource(.nzb)
        }
    }

    public func items() async throws -> [LibraryItem] {
        async let torrents = pages("seedbox/list", as: DebridLinkTorrent.self)
        async let links = pages("downloader/list", as: DebridLinkLink.self)
        let items = try await torrents.map { $0.libraryItem() } + links.map { $0.libraryItem() }
        return items.sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
    }

    /// Asks for this one item, so torrents with many files list them all instead of their ZIP.
    public func item(_ itemID: LibraryItem.ID) async throws -> LibraryItem {
        switch DebridLinkItemRef(itemID) {
        case .torrent(let id): try await torrent(id).libraryItem()
        case .link(let id): try await link(id).libraryItem()
        case nil: throw BackendError.notFound
        }
    }

    public func delete(_ itemID: LibraryItem.ID) async throws {
        let path = switch DebridLinkItemRef(itemID) {
        case .torrent(let id): "seedbox/\(id)/remove"
        case .link(let id): "downloader/\(id)/remove"
        case nil: throw BackendError.notFound
        }
        _ = try await perform(request(path, method: "DELETE"), as: DebridLinkIgnored.self)
    }

    public func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
        let link: String?
        switch DebridLinkItemRef(itemID) {
        case .torrent(let id):
            guard let file = try await torrent(id).files?.first(where: { $0.id == fileID }) else { throw BackendError.notFound }
            guard (file.downloadPercent ?? 0) >= 100 else {
                throw BackendError.api(message: "This file is still downloading on Debrid-Link.")
            }
            link = file.downloadUrl
        case .link(let id):
            let current = try await self.link(id)
            if current.expired == true, let original = current.url {
                link = try await addLink(original).first?.downloadUrl
            } else {
                link = current.downloadUrl
            }
        case nil:
            throw BackendError.notFound
        }
        guard let link, let url = URL(string: link) else { throw BackendError.invalidResponse }
        return URLRequest(url: url)
    }

    // MARK: - Helpers

    private func torrent(_ id: String) async throws -> DebridLinkTorrent {
        let list = try await perform(request("seedbox/list", query: [URLQueryItem(name: "ids", value: id)]), as: [DebridLinkTorrent].self)
        guard let torrent = list.first(where: { $0.id == id }) else { throw BackendError.notFound }
        return torrent
    }

    private func link(_ id: String) async throws -> DebridLinkLink {
        let list = try await perform(request("downloader/list", query: [URLQueryItem(name: "ids", value: id)]), as: [DebridLinkLink].self)
        guard let link = list.first(where: { $0.id == id }) else { throw BackendError.notFound }
        return link
    }

    /// One link, or every file's for a folder link.
    private func addLink(_ url: String, password: String? = nil) async throws -> [DebridLinkLink] {
        var body = ["url": url]
        if let password, !password.isEmpty { body["password"] = password }
        return try await perform(jsonRequest("downloader/add", body: body), as: DebridLinkLinks.self).links
    }

    /// Every page of a list endpoint, 100 items at a time.
    private func pages<T: Decodable>(_ path: String, as type: T.Type) async throws -> [T] {
        var all: [T] = []
        var page = 0
        while true {
            let query = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "perPage", value: "100")]
            let envelope = try await send(request(path, query: query), as: [T].self)
            all += envelope.value ?? []
            guard let next = envelope.pagination?.next, next > page, page < 50 else { return all }
            page = next
        }
    }

    private func jsonRequest(_ path: String, body: [String: String]) -> URLRequest {
        let data = try? JSONSerialization.data(withJSONObject: body)
        return request(path, method: "POST", body: data, contentType: "application/json")
    }

    private func request(
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
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// The envelope's `value`, which must be there.
    private func perform<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        guard let value = try await send(request, as: type).value else { throw BackendError.invalidResponse }
        return value
    }

    /// Sends the request and unwraps the envelope. Errors come as `{"success": false, "error": "<code>"}`,
    /// whatever the HTTP status; the code decides the message.
    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> DebridLinkEnvelope<T> {
        let (data, response) = try await transport.send(request)
        guard let envelope = try? JSONDecoder().decode(DebridLinkEnvelope<T>.self, from: data) else {
            throw response.backendError ?? BackendError.invalidResponse
        }
        guard envelope.success else { throw Self.error(for: envelope.error) }
        return envelope
    }

    /// Codes from `api_doc/errors`.
    static func error(for code: String?) -> BackendError {
        switch code {
        case "badToken", "access_denied", "invalid_grant": .unauthorized
        case "floodDetected": .rateLimited
        case "badId": .notFound
        case "infringingFile": .api(message: "Debrid-Link: this file is unavailable for legal reasons.")
        case "notAddTorrent": .api(message: "Debrid-Link could not add the torrent.")
        case "torrentTooBig": .api(message: "Debrid-Link: the torrent is too big or has too many files.")
        case "maxTorrent": .api(message: "Debrid-Link: daily limit of new torrents reached.")
        case "maxTransfer": .api(message: "Debrid-Link: too many torrents downloading at once. Try again when one finishes.")
        case "badTorrentFile": .api(message: "Debrid-Link: the torrent file is invalid.")
        case "hostNotValid": .api(message: "Debrid-Link does not support this host.")
        case "fileNotFound": .api(message: "The file was not found on the host.")
        case "fileNotAvailable", "notDebrid": .api(message: "The file is temporarily unavailable. Try again later.")
        case "badFileUrl": .api(message: "Debrid-Link: the link format is invalid.")
        case "maintenanceHost": .api(message: "This host is under maintenance on Debrid-Link.")
        case "maxLink", "maxLinkHost", "maxData", "maxDataHost": .api(message: "Debrid-Link: daily limit reached for this host.")
        case "notFreeHost", "unverifiedEmail", "freeServerOverload": .api(message: "Debrid-Link needs a premium account for this.")
        case "badArguments": .api(message: "Debrid-Link rejected the request (bad arguments).")
        case "internalError", "server_error": .api(message: "Debrid-Link had an internal error. Try again later.")
        case let code?: .api(message: "Debrid-Link: \(code)")
        case nil: .invalidResponse
        }
    }
}

extension DebridLinkBackend: AccountReporting {
    /// `GET account/infos`: `accountType` 0 free, 1 premium, 2 lifetime; `premiumLeft` in seconds.
    public func account() async throws -> AccountStatus {
        let account = try await perform(request("account/infos"), as: DebridLinkAccount.self)
        switch account.accountType ?? 0 {
        case 2:
            return AccountStatus(isPremium: true, plan: "Lifetime")
        case 1:
            let left = account.premiumLeft ?? 0
            return AccountStatus(isPremium: left > 0, premiumUntil: left > 0 ? Date(timeIntervalSinceNow: left) : nil)
        default:
            return AccountStatus(isPremium: false)
        }
    }
}

extension DebridLinkBackend {
    /// A folder link answers with every file's link: each is its own item.
    @discardableResult
    public func addAll(_ source: Source, category: AddCategory?, privateTracker: Bool) async throws -> [LibraryItem.ID] {
        guard case .hosterURL(let url, let password) = source else {
            return [try await add(source, category: category, privateTracker: privateTracker)]
        }
        let links = try await addLink(url.absoluteString, password: password)
        guard !links.isEmpty else { throw BackendError.invalidResponse }
        return links.map { DebridLinkItemRef.link($0.id).id }
    }
}

extension DebridLinkBackend: HosterListing {
    /// `GET downloader/hosts`: hosters (`type` "host"; "stream" and "protect" sites too), online while
    /// `status` ≥ 1.
    public func hostList() async throws -> HostList {
        let query = [URLQueryItem(name: "keys", value: "name,type,status,domains")]
        let hosts = try await perform(request("downloader/hosts", query: query), as: [DebridLinkHost].self)
        return HostList(hosts: hosts.map {
            HostList.Host(name: $0.name, domains: $0.domains ?? [], online: $0.status.map { $0 >= 1 })
        })
    }
}

struct DebridLinkHost: Decodable {
    let name: String
    let type: String?
    let status: Int?
    let domains: [String]?
}
