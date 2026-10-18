import Foundation

/// A book metadata provider the user added by URL, in Audiobookshelf's custom metadata provider format
/// (`GET {url}/search?query=…&mediaType=book`, optional `Authorization` header, `{"matches": [...]}`). The
/// community runs them for sources without an official API (Storytel, lubimyczytac, Goodreads…); Dove only
/// knows the format, never the source.
public struct BookProvider: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// The provider's base URL; `/search` is appended. It may carry a token, so it lives in the Keychain.
    public var url: URL
    /// Sent as the `Authorization` header when set.
    public var authorization: String?
    public var enabled: Bool

    public init(id: String = UUID().uuidString, name: String, url: URL, authorization: String? = nil, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.authorization = authorization
        self.enabled = enabled
    }

    /// `{url}/search`, keeping any query the URL had. A pasted URL that already ends in `/search` is kept.
    var searchURL: URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = path.hasSuffix("/search") ? path : path + "/search"
        return components.url!
    }

    /// A pasted address: `https://` added when missing.
    public static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let full = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: full), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host() != nil
        else { return nil }
        return url
    }
}
