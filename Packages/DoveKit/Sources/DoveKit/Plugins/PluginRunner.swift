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

/// The movie or series a plugin's `search` is for, once the user picked it (`docs/plugins.md`, `Title`):
/// its name, year and IDs, and the episode or season when the sources are for one.
public struct PluginTitle: Sendable, Hashable {
    public var name: String
    public var type: MediaType
    public var year: Int?
    public var imdbID: String?
    public var tmdbID: String?
    public var season: Int?
    public var episode: Int?

    public init(name: String, type: MediaType, year: Int? = nil, imdbID: String? = nil, tmdbID: String? = nil, season: Int? = nil, episode: Int? = nil) {
        self.name = name
        self.type = type
        self.year = year
        self.imdbID = imdbID
        self.tmdbID = tmdbID
        self.season = season
        self.episode = episode
    }

    /// From a source list: the stream ID (`tt…`, `tt…:1:2`, `tmdb:…`) gives the IDs and the episode; a pack
    /// scope keeps only the season (or neither, for whole series).
    public init(name: String, type: MediaType, streamID: String, media: MediaSummary? = nil, scope: PackScope? = nil) {
        let parts = streamID.split(separator: ":").map(String.init)
        let ids = [streamID, media?.id].compactMap { $0 }
        self.init(
            name: name,
            type: type,
            year: media?.releaseInfo.flatMap { Int($0.prefix(4)) },
            imdbID: ids.lazy.compactMap { $0.split(separator: ":").first.map(String.init) }.first { $0.hasPrefix("tt") },
            tmdbID: ids.first { $0.hasPrefix("tmdb:") }.map { String($0.split(separator: ":")[1]) }
        )
        guard type == .series else { return }
        let numbers = parts.compactMap(Int.init)
        let codes = parts.first?.hasPrefix("tt") == true && numbers.count >= 2 ? (numbers[numbers.count - 2], numbers[numbers.count - 1]) : nil
        switch scope {
        case .season(let number): season = number
        case .series: break
        case nil: (season, episode) = (codes?.0, codes?.1)
        }
    }

    /// The words a plugin without its own title handling can search with: "Name 2019", "Name S01E02", "Name S01".
    public var query: String {
        switch (season, episode) {
        case let (season?, episode?): String(format: "%@ S%02dE%02d", name, season, episode)
        case let (season?, nil): String(format: "%@ S%02d", name, season)
        default: [name, year.map(String.init)].compactMap { $0 }.joined(separator: " ")
        }
    }

    var argument: [String: Any] {
        let optional: [String: Any?] = ["year": year, "imdb": imdbID, "tmdb": tmdbID, "season": season, "episode": episode]
        return optional.compactMapValues { $0 }.merging(["name": name, "type": type.rawValue]) { $1 }
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

    /// Music metadata: `metadata({query, category: "music"})` answers albums (`docs/plugins.md`, `Album`).
    public func albums(_ plugin: PluginManifest, script: String, settings: [String: SettingValue], query: String) async throws -> [AlbumSummary] {
        let json = try await call(plugin, script: script, settings: settings, function: "metadata", argument: [
            "query": query, "category": SearchCategory.music.rawValue,
        ])
        return try decodeList(PluginAlbum.self, json).map { $0.summary(plugin: plugin.id) }
    }

    /// An album's tracks (`tracks({id})`, optional: a plugin without it has none to give).
    public func tracks(_ plugin: PluginManifest, script: String, settings: [String: SettingValue], albumID: String) async throws -> [AlbumTrack] {
        let json = try await call(plugin, script: script, settings: settings, function: "tracks", argument: ["id": albumID])
        return try decodeList(PluginTrack.self, json).enumerated().map { index, track in
            AlbumTrack(id: track.id ?? "\(albumID)/\(index)", disc: track.disc ?? 1, position: track.position ?? index + 1, title: track.title, duration: track.duration)
        }
    }

    public func search(
        _ plugin: PluginManifest, script: String, settings: [String: SettingValue],
        query: String, category: SearchCategory, book: BookSummary? = nil, title: PluginTitle? = nil, album: AlbumSummary? = nil
    ) async throws -> [PluginResult] {
        var argument: [String: Any] = ["query": query, "category": category.rawValue]
        if let book {
            let year: [String: Any?] = ["year": book.year]
            argument["book"] = year.compactMapValues { $0 }.merging(["title": book.title, "authors": book.authors]) { $1 }
        }
        if let title { argument["title"] = title.argument }
        if let album {
            let year: [String: Any?] = ["year": album.year]
            argument["album"] = year.compactMapValues { $0 }.merging(["title": album.title, "artists": album.artists]) { $1 }
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

    func call(
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

    func decodeList<T: Decodable>(_ type: T.Type, _ json: String) throws -> [T] {
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

/// An album from a plugin's `metadata` for Music (`docs/plugins.md`, `Album`).
struct PluginAlbum: Decodable {
    var id: String
    var title: String
    var artists: [String]
    var year: Int?
    var cover: URL?
    var type: String?
    var link: URL?

    enum CodingKeys: String, CodingKey { case id, title, artists, artist, year, cover, type, link }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLenientString(.id)
        title = try c.decode(String.self, forKey: .title)
        let one = (try? c.decodeIfPresent(String.self, forKey: .artist)).flatMap { $0 }
        artists = (try? c.decodeIfPresent([String].self, forKey: .artists)).flatMap { $0 } ?? one.map { [$0] } ?? []
        year = c.decodeLenientInt64(.year).map(Int.init)
        cover = c.decodeLenientURL(.cover)
        // `album`, `ep`, `single`, `compilation`… in any case: shown like MusicBrainz's ("EP", "Single").
        type = (try? c.decodeIfPresent(String.self, forKey: .type)).flatMap { $0 }.map { $0.lowercased() == "ep" ? "EP" : $0.capitalized }
        link = c.decodeLenientURL(.link)
    }

    func summary(plugin: String) -> AlbumSummary {
        AlbumSummary(id: "plugin:\(plugin):\(id)", title: title, artists: artists, year: year, cover: cover, type: type, link: link)
    }
}

/// A track from a plugin's `tracks` (`docs/plugins.md`, `Track`): duration in seconds.
struct PluginTrack: Decodable {
    var id: String?
    var title: String
    var disc: Int?
    var position: Int?
    var duration: TimeInterval?

    enum CodingKeys: String, CodingKey { case id, title, disc, position, duration }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeLenientString(.id)
        title = try c.decode(String.self, forKey: .title)
        disc = c.decodeLenientInt64(.disc).map(Int.init)
        position = c.decodeLenientInt64(.position).map(Int.init)
        duration = c.decodeLenientInt64(.duration).map(TimeInterval.init)
    }
}

/// A plugin with music `metadata` as an album source beside MusicBrainz.
public struct PluginAlbumCatalog: AlbumCatalog {
    public let call: PluginCall
    let transport: any HTTPTransport

    public init(call: PluginCall, transport: any HTTPTransport = URLSession.shared) {
        self.call = call
        self.transport = transport
    }

    public var name: String { call.manifest.name }
    var prefix: String { "plugin:\(call.id):" }

    public func owns(_ albumID: String) -> Bool { albumID.hasPrefix(prefix) }

    public func albums(matching query: String) async throws -> [AlbumSummary] {
        try await PluginRunner(transport: transport).albums(call.manifest, script: call.script, settings: call.settings, query: query)
    }

    public func tracks(ofAlbum id: String) async throws -> [AlbumTrack] {
        guard owns(id) else { return [] }
        return try await PluginRunner(transport: transport).tracks(
            call.manifest, script: call.script, settings: call.settings, albumID: String(id.dropFirst(prefix.count))
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
