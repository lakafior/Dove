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
public struct RealDebridBackend: LibraryBackend, FileSelecting {
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
        try refusePrivateTorrent(source)
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

        case .hosterURL(let url, let password):
            let download = try await unrestrict(url.absoluteString, password: password)
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

    // MARK: - FileSelecting

    public func selectableFiles(_ itemID: LibraryItem.ID) async throws -> FileSelection {
        guard case .torrent(let id) = RealDebridItemRef(itemID) else { throw BackendError.notFound }
        let torrent = try await info(id)
        guard torrent.status == "waiting_files_selection" else {
            throw BackendError.api(message: "Real-Debrid is not waiting for a file selection on this torrent.")
        }
        let files = torrent.files ?? []
        let suggested = RealDebridFiles.suggested(files)
        return FileSelection(
            files: files.sorted { $0.id < $1.id }.map {
                // The path shows folders such as "Extras/"; drop RD's leading slash.
                LibraryFile(id: String($0.id), name: String($0.path.drop { $0 == "/" }), size: $0.bytes)
            },
            suggested: Set((suggested.isEmpty ? files : suggested).map { String($0.id) })
        )
    }

    public func selectFiles(_ itemID: LibraryItem.ID, fileIDs: Set<LibraryFile.ID>) async throws {
        guard case .torrent(let id) = RealDebridItemRef(itemID) else { throw BackendError.notFound }
        guard !fileIDs.isEmpty else { throw BackendError.api(message: "Choose at least one file.") }
        let files = fileIDs.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.joined(separator: ",")
        _ = try await send(request("torrents/selectFiles/\(id)", method: "POST", form: [("files", files)]))
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

    private func unrestrict(_ link: String, password: String? = nil) async throws -> RealDebridDownload {
        var form = [("link", link)]
        if let password, !password.isEmpty { form.append(("password", password)) }
        return try await decode(RealDebridDownload.self, from: request("unrestrict/link", method: "POST", form: form))
    }

    /// `/downloads` has no single-entry endpoint, so look the entry up in the list.
    private func findDownload(_ id: String) async throws -> RealDebridDownload {
        guard let match = try await paged(RealDebridDownload.self, path: "downloads").first(where: { $0.id == id }) else {
            throw BackendError.notFound
        }
        return match
    }

    /// Selects video files once the magnet is converted. Gives up quietly if conversion takes longer;
    /// the item then shows as awaiting file selection and the user picks files in the item view.
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

extension RealDebridBackend: AccountReporting {
    /// `GET /user`: `type` is "premium" or "free", `expiration` the premium's end (ISO 8601).
    public func account() async throws -> AccountStatus {
        let user = try await decode(RealDebridUser.self, from: request("user"))
        let isPremium = user.type == "premium"
        return AccountStatus(isPremium: isPremium, premiumUntil: isPremium ? AccountDate.parse(user.expiration) : nil)
    }
}

struct RealDebridUser: Decodable {
    let type: String?
    let expiration: String?
}

extension RealDebridBackend {
    /// A link `unrestrict/link` refuses may be a folder: `unrestrict/folder` lists its files' links, each
    /// unrestricted into its own `/downloads` entry. Files that fail are skipped; all failing throws the first error.
    @discardableResult
    public func addAll(_ source: Source, category: AddCategory?, privateTracker: Bool) async throws -> [LibraryItem.ID] {
        guard case .hosterURL(let url, let password) = source else {
            return [try await add(source, category: category, privateTracker: privateTracker)]
        }
        do {
            return [try await add(source)]
        } catch let error as BackendError where error != .unauthorized && error != .rateLimited {
            let links = (try? await decode([String].self, from: request("unrestrict/folder", method: "POST", form: [("link", url.absoluteString)]))) ?? []
            guard !links.isEmpty else { throw error }
            var ids: [LibraryItem.ID] = []
            var firstError: (any Error)?
            for link in links {
                do {
                    ids.append(RealDebridItemRef.download(try await unrestrict(link, password: password).id).id)
                } catch {
                    firstError = firstError ?? error
                }
            }
            if ids.isEmpty, let firstError { throw firstError }
            return ids
        }
    }
}

extension RealDebridBackend: HosterListing {
    /// `GET hosts` (domain → name, public) grouped by name, with `hosts/status` (`status` "up"/"down") when it
    /// answers; a failing status call leaves every hoster's state unknown.
    public func hostList() async throws -> HostList {
        let hosts = try await decode([String: RealDebridHost].self, from: request("hosts"))
        let status = (try? await decode([String: RealDebridHostStatus].self, from: request("hosts/status"))) ?? [:]
        var byName: [String: (domains: [String], online: Bool?)] = [:]
        for (domain, host) in hosts {
            var entry = byName[host.name, default: ([], nil)]
            entry.domains.append(domain)
            switch status[domain]?.status?.lowercased() {
            case "up": entry.online = true
            case "down": entry.online = entry.online ?? false
            default: break
            }
            byName[host.name] = entry
        }
        return HostList(hosts: byName
            .map { HostList.Host(name: $0.key, domains: $0.value.domains.sorted(), online: $0.value.online) }
            .sorted { $0.name < $1.name })
    }
}

struct RealDebridHost: Decodable {
    let name: String
}

struct RealDebridHostStatus: Decodable {
    let status: String?
}

extension RealDebridBackend: HosterChecking {
    /// `POST unrestrict/check`: the file's name and size from the hoster, `supported` 1 when Real-Debrid can
    /// unlock it. Adds nothing. A file that is gone answers with an error (code 24), reported as unavailable.
    public func check(_ url: URL, password: String?) async throws -> HosterLinkInfo {
        var form = [("link", url.absoluteString)]
        if let password, !password.isEmpty { form.append(("password", password)) }
        do {
            let check = try await decode(RealDebridLinkCheck.self, from: request("unrestrict/check", method: "POST", form: form))
            return HosterLinkInfo(filename: check.filename, size: check.filesize, host: check.host, available: check.supported != 0)
        } catch let error as BackendError where error == Self.map(errorCode: 24, message: nil) {
            return HosterLinkInfo(filename: nil, size: nil, host: url.host(), available: false)
        }
    }
}

struct RealDebridLinkCheck: Decodable {
    let host: String?
    let filename: String?
    let filesize: Int64?
    let supported: Int?
}
