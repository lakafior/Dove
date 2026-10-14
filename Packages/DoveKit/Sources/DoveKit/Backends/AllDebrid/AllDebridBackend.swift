import Foundation

/// AllDebrid adapter (docs.alldebrid.com, API v4 / v4.1).
///
/// - Auth: `Authorization: Bearer <key>`. The `agent` parameter is no longer required (changelog 2025-01-15).
/// - Torrents: `POST v4/magnet/upload` (`magnets[]`), `POST v4/magnet/upload/file` (multipart `files[0]`); a
///   `.torrent` URL is fetched on the phone first. Status: `POST v4.1/magnet/status` (`statusCode` 0–3 working,
///   4 ready, 5–15 errors). Files: `POST v4/magnet/files` (`id[]`), a tree whose file links (`l`) are unlocked like
///   hoster links. Delete: `POST v4/magnet/delete` (`id`).
/// - Hoster links: `POST v4/link/unlock` (`link`, `password`) checks the link, then `POST v4/user/links/save`
///   (`links[]`) keeps it in the account, which is AllDebrid's only list of them (`GET v4/user/links`). Folder and
///   redirector links: `POST v4/link/redirector` gives the files' links. Downloads unlock again; a `delayed` answer
///   is polled with `POST v4/link/delayed` until `status` 2. Delete: `POST v4/user/links/delete`.
/// - No cache check (the instant endpoint is gone). Hosters: `GET v4/hosts` (public). Account: `GET v4/user`.
/// - Errors: `{"status": "error", "error": {"code", "message"}}` (`AUTH_BAD_APIKEY`, `LINK_HOST_NOT_SUPPORTED`,
///   `LINK_PASS_PROTECTED`, `MAGNET_TOO_MANY_ACTIVE`…). Limits: 12 requests a second, 600 a minute.
public struct AllDebridBackend: LibraryBackend {
    public let id: BackendID = .allDebrid
    public let supportedSources: Set<SourceKind> = [.torrent, .hoster]

    private let apiKey: String
    private let transport: any HTTPTransport
    private let baseURL: URL
    private let delayedInterval: Duration
    private let delayedAttempts: Int

    public init(
        apiKey: String,
        transport: any HTTPTransport = URLSession.shared,
        baseURL: URL = URL(string: "https://api.alldebrid.com")!,
        delayedInterval: Duration = .seconds(2),
        delayedAttempts: Int = 15
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.baseURL = baseURL
        self.delayedInterval = delayedInterval
        self.delayedAttempts = delayedAttempts
    }

    // MARK: - LibraryBackend

    public func validateCredentials() async throws {
        let user = try await perform(request("v4/user"), as: AllDebridUserData.self).user
        if user.isPremium == false {
            throw BackendError.api(message: "This AllDebrid account is not premium.")
        }
    }

    @discardableResult
    public func add(_ source: Source) async throws -> LibraryItem.ID {
        guard let first = try await addAll(source, category: nil, privateTracker: false).first else {
            throw BackendError.invalidResponse
        }
        return first
    }

    /// A folder or redirector link becomes one saved link per file.
    @discardableResult
    public func addAll(_ source: Source, category: AddCategory?, privateTracker: Bool) async throws -> [LibraryItem.ID] {
        if privateTracker { throw BackendError.privateTorrent }
        try refusePrivateTorrent(source)
        switch source {
        case .magnet(let magnet):
            let uploads = try await perform(request("v4/magnet/upload", form: [("magnets[]", magnet)]), as: AllDebridUploads.self)
            return [try Self.uploadedID(uploads.magnets)]
        case .torrentFile(let data, let filename):
            var form = MultipartFormData()
            form.addFile("files[0]", filename: filename, mimeType: "application/x-bittorrent", data: data)
            let uploads = try await perform(
                request("v4/magnet/upload/file", body: form.finalized(), contentType: form.contentType),
                as: AllDebridUploads.self
            )
            return [try Self.uploadedID(uploads.files)]
        case .torrentURL(let url):
            // AllDebrid takes the file itself.
            let (data, response) = try await transport.send(URLRequest(url: url))
            if let error = response.backendError { throw error }
            let filename = url.lastPathComponent.lowercased().hasSuffix(".torrent") ? url.lastPathComponent : "download.torrent"
            return try await addAll(.torrentFile(data: data, filename: filename), category: category, privateTracker: privateTracker)
        case .hosterURL(let url, let password):
            return try await addLink(url.absoluteString, password: password)
        case .nzbURL, .nzbFile:
            throw BackendError.unsupportedSource(.nzb)
        }
    }

    public func items() async throws -> [LibraryItem] {
        async let magnets = magnetStatus()
        async let links = perform(request("v4/user/links", method: "GET"), as: AllDebridSavedLinks.self)
        let all = try await magnets.map { $0.libraryItem() } + links.links.map(\.libraryItem)
        return all.sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
    }

    public func item(_ itemID: LibraryItem.ID) async throws -> LibraryItem {
        switch AllDebridItemRef(itemID) {
        case .magnet(let id):
            guard let magnet = try await magnetStatus(id: id).first(where: { $0.id.value == id }) else { throw BackendError.notFound }
            guard magnet.libraryStatus == .ready else { return magnet.libraryItem() }
            let files = try await magnetFiles(id)
            return magnet.libraryItem(files: Self.libraryFiles(files))
        case .link:
            guard let match = try await items().first(where: { $0.id == itemID }) else { throw BackendError.notFound }
            return match
        case nil:
            throw BackendError.notFound
        }
    }

    public func delete(_ itemID: LibraryItem.ID) async throws {
        switch AllDebridItemRef(itemID) {
        case .magnet(let id):
            _ = try await perform(request("v4/magnet/delete", form: [("id", String(id))]), as: AllDebridMessage.self)
        case .link(let link):
            _ = try await perform(request("v4/user/links/delete", form: [("links[]", link)]), as: AllDebridMessage.self)
        case nil:
            throw BackendError.notFound
        }
    }

    public func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
        let link: String
        switch AllDebridItemRef(itemID) {
        case .magnet(let id):
            let files = try await magnetFiles(id)
            guard let index = Int(fileID), files.indices.contains(index) else { throw BackendError.notFound }
            link = files[index].link
        case .link(let saved):
            link = saved
        case nil:
            throw BackendError.notFound
        }
        return URLRequest(url: try await unlock(link, password: nil))
    }

    // MARK: - Helpers

    private func magnetStatus(id: Int? = nil) async throws -> [AllDebridMagnet] {
        let form = id.map { [("id", String($0))] } ?? []
        return try await perform(request("v4.1/magnet/status", form: form), as: AllDebridMagnets.self).magnets
    }

    private func magnetFiles(_ id: Int) async throws -> [(path: String, size: Int64?, link: String)] {
        let answer = try await perform(request("v4/magnet/files", form: [("id[]", String(id))]), as: AllDebridMagnetFiles.self)
        guard let entry = answer.magnets.first(where: { $0.id.value == id }) else { throw BackendError.notFound }
        if let error = entry.error { throw Self.error(code: error.code, message: error.message) }
        return (entry.files ?? []).flatMap { $0.flattened() }
    }

    /// Paths without the torrent's own root folder when every file sits in it; IDs are indexes.
    static func libraryFiles(_ files: [(path: String, size: Int64?, link: String)]) -> [LibraryFile] {
        let paths = files.map { $0.path.split(separator: "/").map(String.init) }
        let roots = Set(paths.compactMap { $0.count > 1 ? $0[0] : nil })
        let dropRoot = roots.count == 1 && paths.allSatisfy { $0.count > 1 }
        return zip(files, paths).enumerated().map { index, pair in
            let components = dropRoot ? Array(pair.1.dropFirst()) : pair.1
            return LibraryFile(id: String(index), name: components.joined(separator: "/"), size: pair.0.size)
        }
    }

    /// Unlocks the link to check it, then saves it. A link AllDebrid cannot unlock may be a folder or redirector:
    /// its files are saved instead.
    private func addLink(_ link: String, password: String?) async throws -> [LibraryItem.ID] {
        do {
            _ = try await unlockAnswer(link, password: password)
        } catch let error as BackendError where error != .unauthorized && error != .rateLimited {
            guard let links = try? await perform(request("v4/link/redirector", form: [("link", link)]), as: AllDebridRedirected.self).links,
                  !links.isEmpty else { throw error }
            try await save(links)
            return links.map { AllDebridItemRef.link($0).id }
        }
        try await save([link])
        return [AllDebridItemRef.link(link).id]
    }

    private func save(_ links: [String]) async throws {
        _ = try await perform(request("v4/user/links/save", form: links.map { ("links[]", $0) }), as: AllDebridMessage.self)
    }

    private func unlockAnswer(_ link: String, password: String?) async throws -> AllDebridUnlocked {
        var form = [("link", link)]
        if let password, !password.isEmpty { form.append(("password", password)) }
        return try await perform(request("v4/link/unlock", form: form), as: AllDebridUnlocked.self)
    }

    /// A direct download URL, waiting for delayed links (some hosters prepare the file first).
    func unlock(_ link: String, password: String?) async throws -> URL {
        let answer = try await unlockAnswer(link, password: password)
        if let direct = answer.link, !direct.isEmpty, let url = URL(string: direct) { return url }
        guard let delayed = answer.delayed?.value else { throw BackendError.invalidResponse }
        for _ in 0..<delayedAttempts {
            let state = try await perform(request("v4/link/delayed", form: [("id", String(delayed))]), as: AllDebridDelayed.self)
            switch state.status {
            case 2:
                guard let direct = state.link, let url = URL(string: direct) else { throw BackendError.invalidResponse }
                return url
            case 3:
                throw BackendError.api(message: "AllDebrid could not prepare this file.")
            default:
                try await Task.sleep(for: delayedInterval)
            }
        }
        throw BackendError.api(message: "AllDebrid is still preparing this file. Try again in a minute.")
    }

    static func uploadedID(_ uploads: [AllDebridUpload]?) throws -> LibraryItem.ID {
        guard let upload = uploads?.first else { throw BackendError.invalidResponse }
        if let failure = upload.error { throw error(code: failure.code, message: failure.message) }
        guard let id = upload.id?.value else { throw BackendError.invalidResponse }
        return AllDebridItemRef.magnet(id).id
    }

    /// POSTs a form unless `method` says otherwise; GETs without a form.
    private func request(
        _ path: String,
        method: String? = nil,
        form: [(String, String)]? = nil,
        body: Data? = nil,
        contentType: String? = nil
    ) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method ?? (form != nil || body != nil ? "POST" : "GET")
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

    /// Unwraps `data`, mapping `error` codes whatever the HTTP status.
    private func perform<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await transport.send(request)
        guard let envelope = try? JSONDecoder().decode(AllDebridEnvelope<T>.self, from: data) else {
            if let error = try? JSONDecoder().decode(AllDebridEnvelope<AllDebridMessage>.self, from: data).error {
                throw Self.error(code: error.code, message: error.message)
            }
            throw response.backendError ?? BackendError.invalidResponse
        }
        if envelope.status == "error" || envelope.data == nil {
            throw Self.error(code: envelope.error?.code, message: envelope.error?.message)
        }
        return envelope.data!
    }

    static func error(code: String?, message: String?) -> BackendError {
        switch code {
        case "AUTH_MISSING_APIKEY", "AUTH_BAD_APIKEY", "AUTH_USER_BANNED": return .unauthorized
        case "AUTH_BLOCKED": return .api(message: "AllDebrid blocked this API key: confirm the new device or IP in the e-mail AllDebrid sent.")
        case "MUST_BE_PREMIUM", "MAGNET_MUST_BE_PREMIUM": return .api(message: "This needs AllDebrid premium.")
        case "LINK_HOST_NOT_SUPPORTED": return .api(message: "AllDebrid does not support this hoster.")
        case "LINK_PASS_PROTECTED": return .api(message: "This link needs a password.")
        case "LINK_DOWN": return .api(message: "The file is unavailable on the hoster.")
        case "LINK_HOST_LIMIT_REACHED", "LINK_HOST_FULL": return .api(message: "AllDebrid's limit for this hoster is reached.")
        case "MAGNET_TOO_MANY_ACTIVE": return .api(message: "Too many active torrents on AllDebrid (30 at most).")
        case "MAGNET_INVALID_URI", "MAGNET_INVALID_FILE": return .api(message: "AllDebrid says this torrent is invalid.")
        case "MAGNET_INVALID_ID", "LINK_IS_MISSING": return .notFound
        default:
            if let message, !message.isEmpty { return .api(message: "AllDebrid: \(message)") }
            return .api(message: "AllDebrid request failed\(code.map { " (\($0))" } ?? "").")
        }
    }
}

/// `data.message` of actions that answer nothing else.
struct AllDebridMessage: Decodable {
    let message: String?
}

extension AllDebridBackend: AccountReporting {
    /// `GET v4/user`: `isPremium`, `premiumUntil` (Unix seconds, 0 without premium).
    public func account() async throws -> AccountStatus {
        let user = try await perform(request("v4/user"), as: AllDebridUserData.self).user
        let until = user.premiumUntil.flatMap { $0.value > 0 ? Date(timeIntervalSince1970: TimeInterval($0.value)) : nil }
        let isPremium = user.isPremium ?? ((until ?? .distantPast) > .now)
        return AccountStatus(isPremium: isPremium, premiumUntil: until)
    }
}

extension AllDebridBackend: HosterListing {
    /// `GET v4/hosts`: each hoster's `domains` and `status` (working in the last minutes).
    public func hostList() async throws -> HostList {
        let hosts = try await perform(request("v4/hosts"), as: AllDebridHosts.self).hosts
        return HostList(hosts: hosts.map { key, host in
            HostList.Host(name: host.name ?? key, domains: host.domains ?? [], online: host.status)
        }.sorted { $0.name < $1.name })
    }
}
