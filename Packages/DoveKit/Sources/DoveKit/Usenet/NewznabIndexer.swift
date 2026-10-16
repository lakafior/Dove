import Foundation

/// One Newznab or Torznab indexer the user searches from the phone (their own IP, so indexers that block
/// shared AIOStreams servers still answer). Prowlarr, NZBHydra and Jackett speak these too and fit here as one
/// entry each. The whole list lives in the Keychain: the API keys are secrets.
public struct NewznabIndexer: Codable, Sendable, Identifiable, Hashable {
    /// Same protocol, different results: Newznab finds NZBs (nzbdav, TorBox Usenet), Torznab finds torrents
    /// (Jackett, Prowlarr; they go to the debrid services).
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case newznab
        case torznab

        public var displayName: String {
            switch self {
            case .newznab: "Newznab (Usenet)"
            case .torznab: "Torznab (torrents)"
            }
        }
    }

    public var id: String
    public var kind: Kind
    public var name: String
    /// Site root (`https://api.nzbgeek.info`); `apiPath` is appended.
    public var url: URL
    public var apiPath: String
    public var apiKey: String
    public var enabled: Bool
    /// API hits per day on the user's plan; nil when unknown or unlimited. Dove stops at it.
    public var dailyLimit: Int?

    public init(
        id: String = UUID().uuidString,
        kind: Kind = .newznab,
        name: String,
        url: URL,
        apiPath: String = "/api",
        apiKey: String,
        enabled: Bool = true,
        dailyLimit: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.url = url
        self.apiPath = apiPath
        self.apiKey = apiKey
        self.enabled = enabled
        self.dailyLimit = dailyLimit
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, url, apiPath, apiKey, enabled, dailyLimit
    }

    /// Lists saved before Torznab existed have no `kind`: they are Newznab.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .newznab
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(URL.self, forKey: .url)
        apiPath = try container.decode(String.self, forKey: .apiPath)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        dailyLimit = try container.decodeIfPresent(Int.self, forKey: .dailyLimit)
    }

    /// The feed it asks, without scheme or case: two indexers with the same feed return the same results
    /// (a Jackett feed pasted twice under different names).
    public var feed: String {
        let address = url.absoluteString.lowercased()
        let bare = address.split(separator: "://", maxSplits: 1).last.map(String.init) ?? address
        return (bare.hasSuffix("/") ? String(bare.dropLast()) : bare) + apiPath.lowercased()
    }

    /// Another indexer in `list` that asks the same feed.
    public func sameFeed(in list: [NewznabIndexer]) -> NewznabIndexer? {
        list.first { $0.id != id && $0.feed == feed }
    }

    /// Accepts what users paste: a site root, or a full `…/api` URL.
    public static func normalized(url text: String) -> (url: URL, apiPath: String)? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard var components = URLComponents(string: trimmed), components.host != nil,
              components.scheme == "https" || components.scheme == "http" else { return nil }
        components.query = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        var apiPath = "/api"
        if path.lowercased().hasSuffix("/api") {
            apiPath = String(path.suffix(4))
            path.removeLast(4)
        }
        components.path = path
        guard let url = components.url else { return nil }
        return (url, apiPath)
    }

    static func load(from keychain: KeychainStore) -> [NewznabIndexer] {
        guard let json = try? keychain.get(.newznabIndexers),
              let list = try? JSONDecoder().decode([NewznabIndexer].self, from: Data(json.utf8))
        else { return [] }
        return list
    }
}

extension SharedConfiguration {
    public static func newznabIndexers(from keychain: KeychainStore) -> [NewznabIndexer] {
        NewznabIndexer.load(from: keychain)
    }

    public static func saveNewznabIndexers(_ indexers: [NewznabIndexer], to keychain: KeychainStore) throws {
        let data = try JSONEncoder().encode(indexers)
        try keychain.set(indexers.isEmpty ? nil : String(decoding: data, as: UTF8.self), for: .newznabIndexers)
    }
}
