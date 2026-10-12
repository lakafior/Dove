import Foundation

/// One Newznab indexer the user searches from the phone (their own IP, so indexers that block shared
/// AIOStreams servers still answer). Prowlarr and NZBHydra speak Newznab too and fit here as one entry.
/// The whole list lives in the Keychain: the API keys are secrets.
public struct NewznabIndexer: Codable, Sendable, Identifiable, Hashable {
    public var id: String
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
        name: String,
        url: URL,
        apiPath: String = "/api",
        apiKey: String,
        enabled: Bool = true,
        dailyLimit: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.apiPath = apiPath
        self.apiKey = apiKey
        self.enabled = enabled
        self.dailyLimit = dailyLimit
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
