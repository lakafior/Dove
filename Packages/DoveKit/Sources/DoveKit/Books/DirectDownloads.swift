import Foundation

/// A site the user adds for direct file downloads: its address and their member key. Dove ships no address;
/// the site's own pages are browsed in-app (search lives there), and Dove takes over at a file's page.
///
/// API (`fastDownloadJSON`): `GET {url}/dyn/api/fast_download.json?md5=<md5>&key=<key>` answers
/// `{"download_url", "error", "account_fast_download_info": {"downloads_left", "downloads_per_day", …}}`; bad
/// answers carry another status, `download_url: null` and `error` as text. The key is checked before the md5.
/// File pages are `{url}/md5/<md5>`. Sites move between domains: the user edits the address.
public struct DirectSource: Codable, Sendable, Hashable, Identifiable {
    public enum API: String, Codable, Sendable, CaseIterable {
        /// `/dyn/api/fast_download.json` with `md5` and `key`.
        case fastDownloadJSON
    }

    public var id: String
    public var name: String
    public var url: URL
    public var key: String
    public var api: API
    public var enabled: Bool
    /// The search categories whose results offer "Search on <site>" (a site may serve books, software…).
    public var categories: [SearchCategory]

    public init(
        id: String = UUID().uuidString,
        name: String,
        url: URL,
        key: String,
        api: API = .fastDownloadJSON,
        enabled: Bool = true,
        categories: [SearchCategory] = [.books]
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.key = key
        self.api = api
        self.enabled = enabled
        self.categories = categories
    }

    enum CodingKeys: String, CodingKey {
        case id, name, url, key, api, enabled, categories
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(URL.self, forKey: .url)
        key = try container.decode(String.self, forKey: .key)
        api = try container.decodeIfPresent(API.self, forKey: .api) ?? .fastDownloadJSON
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        // Saved before sites had categories: books, where they started.
        categories = try container.decodeIfPresent([SearchCategory].self, forKey: .categories) ?? [.books]
    }

    /// Offered in the category's results.
    public func serves(_ category: SearchCategory) -> Bool {
        enabled && categories.contains(category)
    }

    /// The site's search page for words, ebooks only (`ext=` per format) unless `extensions` is empty.
    public func searchURL(_ query: String, extensions: [String] = ["epub"]) -> URL {
        var components = URLComponents(url: root, resolvingAgainstBaseURL: false)!
        components.path = rootPath + "/search"
        components.queryItems = [URLQueryItem(name: "q", value: query)] + extensions.map { URLQueryItem(name: "ext", value: $0) }
        return components.url!
    }

    /// The md5 of a file page (`…/md5/<32 hex>`), on any host: links may come from a mirror.
    public static func md5(in url: URL) -> String? {
        let parts = url.pathComponents
        guard let index = parts.lastIndex(of: "md5"), index + 1 < parts.count else { return nil }
        let hash = parts[index + 1].lowercased()
        return hash.count == 32 && hash.allSatisfy(\.isHexDigit) ? hash : nil
    }

    /// A pasted address: `https://` added when missing, path and query dropped.
    public static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let full = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var components = URLComponents(string: full), let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http", components.host?.isEmpty == false
        else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    var root: URL { url }
    private var rootPath: String {
        let path = url.path()
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    var fastDownloadURL: URL {
        var components = URLComponents(url: root, resolvingAgainstBaseURL: false)!
        components.path = rootPath + "/dyn/api/fast_download.json"
        return components.url!
    }
}

/// Which source and file a direct download came from: enough to ask for a fresh link (they expire).
public struct DirectDownloadRef: Codable, Sendable, Hashable {
    public var sourceID: String
    public var md5: String

    public init(sourceID: String, md5: String) {
        self.sourceID = sourceID
        self.md5 = md5
    }
}

/// The account's fast downloads, as the last answer reported them.
public struct DirectDownloadQuota: Codable, Sendable, Hashable {
    public var left: Int?
    public var perDay: Int?
    public var doneToday: Int?
}

public struct DirectDownloadLink: Sendable, Hashable {
    public var url: URL
    public var quota: DirectDownloadQuota?

    /// The file name the link carries (its last path component), or `<md5>` plus the extension it ends with.
    public func fileName(md5: String) -> String {
        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        guard !last.isEmpty, last.contains(".") else { return md5 }
        return DownloadNaming.sanitized(last)
    }
}

public struct DirectDownloadClient: Sendable {
    private let source: DirectSource
    private let transport: any HTTPTransport

    public init(source: DirectSource, transport: any HTTPTransport = URLSession.shared) {
        self.source = source
        self.transport = transport
    }

    /// A fresh download link for a file. The site counts a download against the day's quota (a file fetched
    /// again soon after is not counted twice).
    public func link(md5: String) async throws -> DirectDownloadLink {
        let answer = try await ask(md5: md5)
        guard let url = answer.downloadURL.flatMap(URL.init(string:)) else {
            throw BackendError.api(message: answer.error ?? "\(source.name) gave no download link.")
        }
        return DirectDownloadLink(url: url, quota: answer.info?.quota)
    }

    /// Checks the key without spending a download: the site checks the key before the md5, so a made-up md5
    /// answers "Invalid secret key" for a wrong key and something else for a right one.
    public func validate() async throws {
        let answer = try await ask(md5: String(repeating: "0", count: 32), allowFailure: true)
        if let error = answer.error, Self.isKeyError(error) { throw BackendError.api(message: error) }
    }

    static func isKeyError(_ error: String) -> Bool {
        let text = error.lowercased()
        return text.contains("secret key") || text.contains("not a member") || text.contains("membership")
    }

    private func ask(md5: String, allowFailure: Bool = false) async throws -> Answer {
        var components = URLComponents(url: source.fastDownloadURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "md5", value: md5), URLQueryItem(name: "key", value: source.key)]
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await transport.send(request)
        // Errors come as JSON with a 4xx; anything else (an HTML page, a parked domain) means a wrong address.
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            if response.statusCode == 404 {
                throw BackendError.api(message: "\(source.url.host() ?? "The address") has no download API. Check the address in Settings.")
            }
            throw response.backendError ?? BackendError.invalidResponse
        }
        if !allowFailure, answer.downloadURL == nil, let error = answer.error {
            throw BackendError.api(message: error)
        }
        return answer
    }

    struct Answer: Decodable {
        var downloadURL: String?
        var error: String?
        var info: Info?

        enum CodingKeys: String, CodingKey {
            case downloadURL = "download_url"
            case error
            case info = "account_fast_download_info"
        }

        struct Info: Decodable {
            var downloadsLeft: Int?
            var downloadsPerDay: Int?
            var downloadsDoneToday: Int?

            enum CodingKeys: String, CodingKey {
                case downloadsLeft = "downloads_left"
                case downloadsPerDay = "downloads_per_day"
                case downloadsDoneToday = "downloads_done_today"
            }

            var quota: DirectDownloadQuota {
                DirectDownloadQuota(left: downloadsLeft, perDay: downloadsPerDay, doneToday: downloadsDoneToday)
            }
        }
    }
}
