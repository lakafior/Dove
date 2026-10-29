import Foundation

/// The file hosters one service unlocks, from its own list endpoint: Real-Debrid `GET hosts` (+ `hosts/status`),
/// TorBox `webdl/hosters`, Debrid-Link `downloader/hosts`. Offcloud has no documented list, so it has none and
/// is always offered for hoster links.
public struct HostList: Codable, Sendable, Equatable {
    public struct Host: Codable, Sendable, Equatable {
        public var name: String
        /// Lowercased, without `www.`.
        public var domains: [String]
        /// False while the service reports the hoster down; nil when it does not say.
        public var online: Bool?
        /// Links left today on this hoster (TorBox, with the account's usage).
        public var linksLeft: Int?

        public init(name: String, domains: [String], online: Bool? = nil, linksLeft: Int? = nil) {
            self.name = name
            self.domains = domains.map { HostList.normalized($0) }
            self.online = online
            self.linksLeft = linksLeft
        }
    }

    public var hosts: [Host]
    public var fetchedAt: Date

    public init(hosts: [Host], fetchedAt: Date = .now) {
        self.hosts = hosts
        self.fetchedAt = fetchedAt
    }

    /// The hoster a link belongs to: its host is one of the domains or a subdomain of one.
    public func host(for url: URL) -> Host? {
        guard let name = url.host().map(Self.normalized), !name.isEmpty else { return nil }
        return hosts.first { host in
            host.domains.contains { name == $0 || name.hasSuffix("." + $0) }
        }
    }

    public func verdict(for url: URL) -> HostVerdict {
        guard let host = host(for: url) else { return .unsupported }
        if host.online == false { return .offline(host.name) }
        if let left = host.linksLeft, left <= 0 { return .limitReached(host.name) }
        return .supported(host.name)
    }

    static func normalized(_ domain: String) -> String {
        let lower = domain.lowercased().trimmingCharacters(in: .whitespaces)
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }
}

/// What a service says about one hoster link.
public enum HostVerdict: Sendable, Equatable {
    case supported(String)
    /// The service lists the hoster but reports it down.
    case offline(String)
    /// Today's links on this hoster are used up.
    case limitReached(String)
    /// Not on the service's list.
    case unsupported
    /// The service has no list, or it could not be loaded: worth trying.
    case unknown

    /// Whether "Automatic" should try the service.
    public var isWorthTrying: Bool {
        switch self {
        case .supported, .unknown: true
        case .offline, .limitReached, .unsupported: false
        }
    }

    /// For the add sheet, next to the service's name.
    public var summary: String? {
        switch self {
        case .supported: nil
        case .offline(let name): "\(name) is down there"
        case .limitReached(let name): "\(name): today's limit reached"
        case .unsupported: "Does not support this site"
        case .unknown: nil
        }
    }
}

/// Backends that can say which hosters they unlock.
public protocol HosterListing: Sendable {
    func hostList() async throws -> HostList
}

/// What a hoster says about a link before anything is added (Real-Debrid `unrestrict/check`).
public struct HosterLinkInfo: Sendable, Equatable {
    public var filename: String?
    public var size: Int64?
    public var host: String?
    /// False when the file is gone or the hoster is not supported.
    public var available: Bool

    public init(filename: String?, size: Int64?, host: String?, available: Bool) {
        self.filename = filename
        self.size = size
        self.host = host
        self.available = available
    }
}

/// Backends that can look at a hoster link without adding it.
public protocol HosterChecking: Sendable {
    func check(_ url: URL, password: String?) async throws -> HosterLinkInfo
}

/// Every service's `HostList`, kept on the device (Caches) and refreshed once a day. Lists that fail to load keep
/// the last copy; a service with no copy at all is `.unknown` for every link.
public actor HostCatalog {
    private let fileURL: URL?
    private let maxAge: TimeInterval
    private var lists: [BackendID: HostList]

    public init(fileURL: URL?, maxAge: TimeInterval = 24 * 60 * 60) {
        self.fileURL = fileURL
        self.maxAge = maxAge
        lists = Self.saved(at: fileURL)
    }

    /// The lists last saved at `fileURL`, read synchronously (for a router built before anything is fetched).
    public static func saved(at fileURL: URL?) -> [BackendID: HostList] {
        fileURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([BackendID: HostList].self, from: $0) } ?? [:]
    }

    /// Caches/Dove/hosts.json of the running process.
    public static var defaultURL: URL {
        DoveStorage.caches.appending(path: "hosts.json")
    }

    public var snapshot: [BackendID: HostList] { lists }

    /// Fetches the lists older than a day (all of them with `force`), in parallel. Returns the result.
    @discardableResult
    public func refresh(_ backends: [any LibraryBackend], force: Bool = false) async -> [BackendID: HostList] {
        let stale = backends.compactMap { backend -> (BackendID, any HosterListing)? in
            guard let listing = backend as? any HosterListing else { return nil }
            if !force, let list = lists[backend.id], Date.now.timeIntervalSince(list.fetchedAt) < maxAge { return nil }
            return (backend.id, listing)
        }
        guard !stale.isEmpty else { return lists }
        let fetched = await withTaskGroup(of: (BackendID, HostList?).self) { group in
            for (id, listing) in stale {
                group.addTask { (id, try? await listing.hostList()) }
            }
            var result: [BackendID: HostList] = [:]
            for await (id, list) in group { if let list { result[id] = list } }
            return result
        }
        lists.merge(fetched) { $1 }
        // Services no longer configured drop out.
        let configured = Set(backends.map(\.id))
        lists = lists.filter { configured.contains($0.key) }
        save()
        return lists
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(lists) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
