import Foundation

/// A search row from a plugin (`docs/plugins.md`, `Result`).
public struct PluginResult: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var author: String?
    public var kind: ContentKind?
    public var format: String?
    public var size: Int64?
    public var language: String?
    public var year: Int?
    public var cover: URL?
    public var link: URL?

    enum CodingKeys: String, CodingKey { case id, title, author, kind, format, size, language, year, cover, link }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLenientString(.id)
        title = try c.decode(String.self, forKey: .title)
        author = try? c.decodeIfPresent(String.self, forKey: .author)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0.flatMap(ContentKind.init(rawValue:)) }
        format = (try? c.decodeIfPresent(String.self, forKey: .format))?.map { $0.lowercased() }
        size = c.decodeLenientInt64(.size)
        language = try? c.decodeIfPresent(String.self, forKey: .language)
        year = c.decodeLenientInt64(.year).map(Int.init)
        cover = c.decodeLenientURL(.cover)
        link = c.decodeLenientURL(.link)
    }
}

/// A file a plugin resolved: Dove downloads it, or hands it to a service when it needs no headers.
public struct PluginLink: Codable, Sendable, Hashable {
    public var url: URL
    public var headers: [String: String]
    public var fileName: String?
    public var size: Int64?

    /// A service can fetch it only when nothing but the URL is needed.
    public var isPlain: Bool { headers.isEmpty }

    enum CodingKeys: String, CodingKey { case url, headers, fileName, size }

    public init(url: URL, headers: [String: String] = [:], fileName: String? = nil, size: Int64? = nil) {
        self.url = url
        self.headers = headers
        self.fileName = fileName
        self.size = size
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let url = c.decodeLenientURL(.url), url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" else {
            throw PluginError("The plugin answered a link that is not http(s).")
        }
        self.url = url
        headers = (try? c.decodeIfPresent([String: String].self, forKey: .headers)) ?? [:]
        fileName = try? c.decodeIfPresent(String.self, forKey: .fileName)
        size = c.decodeLenientInt64(.size)
    }

    /// The file's name: the plugin's, else the URL's last component.
    public var name: String {
        if let fileName, !fileName.isEmpty { return DownloadNaming.sanitized(fileName) }
        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return DownloadNaming.sanitized(last)
    }
}

/// Runs plugin calls: one new JavaScript context each (`PluginSandbox`), the script's hosts as the network
/// policy, the user's settings and the device's locale as `ctx`.
public struct PluginRunner: Sendable {
    let transport: any HTTPTransport
    let timeout: Duration

    public init(transport: any HTTPTransport = URLSession.shared, timeout: Duration = .seconds(30)) {
        self.transport = transport
        self.timeout = timeout
    }

    /// Reads `plugin.manifest` (no network).
    public func manifest(of script: String) async throws -> PluginManifest {
        let json = try await PluginSandbox.run(
            script: script, function: nil, policy: PluginHostPolicy(hosts: [], settings: [:]), transport: transport, timeout: timeout
        )
        do {
            return try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        } catch {
            throw PluginError("The plugin's manifest is not valid: \(error.localizedDescription)")
        }
    }

    public func metadata(
        _ plugin: PluginManifest, script: String, settings: [String: SettingValue], query: String, format: BookFormat
    ) async throws -> [BookSummary] {
        let json = try await call(plugin, script: script, settings: settings, function: "metadata", argument: [
            "query": query, "format": format.rawValue,
        ])
        return try decodeList(PluginBook.self, json).map { $0.summary(plugin: plugin.id) }
    }

    public func search(
        _ plugin: PluginManifest, script: String, settings: [String: SettingValue],
        query: String, category: SearchCategory, book: BookSummary? = nil
    ) async throws -> [PluginResult] {
        var argument: [String: Any] = ["query": query, "category": category.rawValue]
        if let book {
            argument["book"] = ["title": book.title, "authors": book.authors, "year": book.year as Any].compactMapValues { $0 }
        }
        let json = try await call(plugin, script: script, settings: settings, function: "search", argument: argument)
        return try decodeList(PluginResult.self, json)
    }

    /// One link or several (a many-file item).
    public func resolve(_ plugin: PluginManifest, script: String, settings: [String: SettingValue], id: String) async throws -> [PluginLink] {
        let json = try await call(plugin, script: script, settings: settings, function: "resolve", argument: ["id": id])
        let data = Data(json.utf8)
        if let one = try? JSONDecoder().decode(PluginLink.self, from: data) { return [one] }
        let many = try decodeList(PluginLink.self, json)
        guard !many.isEmpty else { throw PluginError("The plugin found no file to download.") }
        return many
    }

    private func call(
        _ plugin: PluginManifest, script: String, settings: [String: SettingValue], function: String, argument: [String: Any]
    ) async throws -> String {
        let values = Self.values(of: plugin, settings: settings)
        if let missing = plugin.settings.first(where: { $0.required && (values[$0.key]?.text.isEmpty ?? true) }) {
            throw PluginError("\(plugin.name) needs “\(missing.title)” in Settings › Plugins.")
        }
        let ctx: [String: Any] = [
            "settings": values.mapValues(\.json),
            "locale": Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
            "region": Locale.current.region?.identifier ?? "",
            "apiVersion": PluginAPI.version,
        ]
        return try await PluginSandbox.run(
            script: script,
            function: function,
            argument: argument,
            ctx: ctx,
            policy: PluginHostPolicy(hosts: plugin.hosts, settings: values.mapValues(\.text)),
            transport: transport,
            timeout: timeout
        )
    }

    /// The user's values over the manifest's defaults.
    static func values(of plugin: PluginManifest, settings: [String: SettingValue]) -> [String: SettingValue] {
        var values: [String: SettingValue] = [:]
        for setting in plugin.settings {
            if let value = settings[setting.key] ?? setting.default { values[setting.key] = value }
        }
        return values
    }

    private func decodeList<T: Decodable>(_ type: T.Type, _ json: String) throws -> [T] {
        guard let items = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any] else {
            if json == "null" { return [] }
            throw PluginError("The plugin answered something other than a list.")
        }
        // A malformed row is skipped, not fatal.
        return items.compactMap { item in
            guard let data = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
    }
}

/// A book from a plugin's `metadata` (`docs/plugins.md`, `Book`).
struct PluginBook: Decodable {
    var id: String
    var title: String
    var authors: [String]
    var year: Int?
    var cover: URL?
    var description: String?
    var link: URL?

    enum CodingKeys: String, CodingKey { case id, title, authors, year, cover, description, link }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLenientString(.id)
        title = try c.decode(String.self, forKey: .title)
        authors = (try? c.decodeIfPresent([String].self, forKey: .authors)) ?? []
        year = c.decodeLenientInt64(.year).map(Int.init)
        cover = c.decodeLenientURL(.cover)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        link = c.decodeLenientURL(.link)
    }

    func summary(plugin: String) -> BookSummary {
        BookSummary(
            id: "plugin:\(plugin):\(id)",
            title: title,
            authors: authors,
            year: year,
            cover: cover,
            description: description.map(ITunesPage.Result.plainText),
            link: link
        )
    }
}

extension KeyedDecodingContainer {
    /// Plugins send ids as strings or numbers.
    func decodeLenientString(_ key: Key) throws -> String {
        if let text = try? decode(String.self, forKey: key) { return text }
        if let number = try? decode(Int64.self, forKey: key) { return String(number) }
        throw PluginError("A plugin result has no \(key.stringValue).")
    }

    /// Numbers as numbers or numeric strings ("2021").
    func decodeLenientInt64(_ key: Key) -> Int64? {
        if let number = try? decodeIfPresent(Int64.self, forKey: key) { return number }
        if let double = try? decodeIfPresent(Double.self, forKey: key) { return Int64(double) }
        return (try? decodeIfPresent(String.self, forKey: key)).flatMap { text in
            text.flatMap { Int64($0) ?? Int64($0.prefix(while: \.isNumber)) }
        }
    }

    func decodeLenientURL(_ key: Key) -> URL? {
        (try? decodeIfPresent(String.self, forKey: key)).flatMap { $0.flatMap { URL(string: $0) } }
    }
}

/// Fetches a repository's index and installs its plugins: the script is downloaded, checked against the
/// index's SHA-256, and its manifest read and compared with the entry.
public struct PluginRepositoryClient: Sendable {
    public static let maxScriptBytes = 2 * 1024 * 1024
    let transport: any HTTPTransport
    let runner: PluginRunner

    public init(transport: any HTTPTransport = URLSession.shared) {
        self.transport = transport
        runner = PluginRunner(transport: transport)
    }

    public func index(at url: URL) async throws -> PluginRepositoryIndex {
        let (data, response) = try await transport.send(Self.get(url))
        if let error = response.backendError { throw error }
        guard let index = try? JSONDecoder().decode(PluginRepositoryIndex.self, from: data), index.format == "dove-plugins" else {
            throw PluginError("\(url.host() ?? "The address") is not a Dove plugin repository.")
        }
        guard index.version == 1 else {
            throw PluginError("This repository needs a newer Dove (format \(index.version)).")
        }
        return index
    }

    /// The verified script and its manifest.
    public func install(_ entry: PluginRepositoryIndex.Entry, from index: URL) async throws -> (plugin: InstalledPlugin, script: String) {
        guard entry.isSupported else { throw PluginError("\(entry.name) needs a newer Dove (plugin API \(entry.api)).") }
        guard let url = entry.scriptURL(relativeTo: index), url.scheme?.lowercased() == "https" else {
            throw PluginError("\(entry.name)'s script is not at an https address.")
        }
        let (data, response) = try await transport.send(Self.get(url))
        if let error = response.backendError { throw error }
        guard data.count <= Self.maxScriptBytes else { throw PluginError("\(entry.name)'s script is larger than 2 MB.") }
        guard PluginChecksum.sha256(data) == entry.sha256.lowercased() else {
            throw PluginError("\(entry.name)'s script does not match the repository's checksum. It was not installed.")
        }
        let script = String(decoding: data, as: UTF8.self)
        let manifest = try await runner.manifest(of: script)
        guard manifest.id == entry.id else {
            throw PluginError("\(entry.name)'s script calls itself \(manifest.id), not \(entry.id).")
        }
        guard manifest.api == PluginAPI.version else { throw PluginError("\(entry.name) needs a newer Dove.") }
        return (InstalledPlugin(repository: index, entry: entry, manifest: manifest), script)
    }

    private static func get(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        // Repositories on GitHub Pages or raw hosts: always the current index.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }
}
