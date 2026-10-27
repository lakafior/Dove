import Foundation

public struct AppVersion: Sendable, Equatable, Hashable, Comparable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let numbers = Optional(parts.compactMap { Int($0) }), numbers.count == parts.count else { return nil }
        var normalized = numbers
        while normalized.count > 1 && normalized.last == 0 { normalized.removeLast() }
        components = normalized
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public var description: String { components.map(String.init).joined(separator: ".") }
}

public struct AvailableUpdate: Sendable, Equatable {
    public let version: AppVersion
    public let tag: String
    public let name: String
    public let notes: String
    public let pageURL: URL
    public let dmgURL: URL?
    public let publishedAt: Date?

    public init(version: AppVersion, tag: String, name: String, notes: String, pageURL: URL, dmgURL: URL?, publishedAt: Date?) {
        self.version = version
        self.tag = tag
        self.name = name
        self.notes = notes
        self.pageURL = pageURL
        self.dmgURL = dmgURL
        self.publishedAt = publishedAt
    }
}

/// The newest published release of Dove on GitHub (`releases/latest` skips drafts and prereleases).
public struct UpdateChecker: Sendable {
    private let transport: any HTTPTransport
    private let repository: String

    public init(transport: any HTTPTransport = URLSession.shared, repository: String = "lakafior/Dove") {
        self.transport = transport
        self.repository = repository
    }

    public func latest(newerThan current: AppVersion) async throws -> AvailableUpdate? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { throw BackendError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Dove", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.send(request)
        if response.statusCode == 404 { return nil }
        if response.statusCode == 403 || response.statusCode == 429 {
            throw BackendError.api(message: "GitHub's limit for update checks was reached. Try again later.")
        }
        guard (200..<300).contains(response.statusCode) else { throw response.backendError ?? BackendError.invalidResponse }
        let release: Release
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            release = try decoder.decode(Release.self, from: data)
        }
        catch { throw BackendError.invalidResponse }
        guard let version = AppVersion(release.tagName), version > current else { return nil }
        return AvailableUpdate(version: version, tag: release.tagName, name: release.name ?? release.tagName,
                              notes: release.body ?? "", pageURL: release.htmlURL,
                              dmgURL: release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") })?.browserDownloadURL,
                              publishedAt: release.publishedAt)
    }

    private struct Release: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: URL
        let publishedAt: Date?
        let assets: [Asset]
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", name, body, htmlURL = "html_url", publishedAt = "published_at", assets }
    }
    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url" }
    }
}
