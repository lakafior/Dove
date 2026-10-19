import Foundation

/// A plugin ready to call: its manifest, verified script and the user's settings.
public struct PluginCall: Sendable, Hashable {
    public var manifest: PluginManifest
    public var script: String
    public var settings: [String: SettingValue]

    public init(manifest: PluginManifest, script: String, settings: [String: SettingValue]) {
        self.manifest = manifest
        self.script = script
        self.settings = settings
    }

    public var id: String { manifest.id }

    /// Its settings with the manifest's defaults, as templates fill them in.
    public var values: [String: String] {
        PluginRunner.values(of: manifest, settings: settings).mapValues(\.text)
    }

    /// The site's own search page for words (`manifest.browse`), when the plugin has one and its settings are set.
    public func browseURL(for query: String) -> URL? {
        guard let template = manifest.browse else { return nil }
        var values = values.mapValues { $0.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? $0 }
        values["query"] = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? query
        return PluginTemplate.fill(template, values: values).flatMap(URL.init(string:))
    }

    /// The id in a file page's address (`manifest.links`), when it is one of this plugin's.
    public func linkID(in url: URL) -> String? {
        manifest.linkID(in: url, values: values)
    }
}

extension PluginManifest {
    /// The id in a file page's address, read with `links` filled from the settings' values. The share extension
    /// uses it without the script.
    public func linkID(in url: URL, values: [String: String]) -> String? {
        let address = url.absoluteString
        for pattern in links {
            guard let filled = PluginTemplate.fillPattern(pattern, values: values),
                  let expression = try? NSRegularExpression(pattern: filled, options: [.caseInsensitive]),
                  let match = expression.firstMatch(in: address, range: NSRange(address.startIndex..., in: address))
            else { continue }
            let range = match.range(withName: "id")
            if range.location != NSNotFound, let swiftRange = Range(range, in: address) { return String(address[swiftRange]) }
        }
        return nil
    }
}

extension PluginStore {
    /// Whether an enabled installed plugin knows this file page (for the share extension, which has no scripts).
    public func knowsLink(_ url: URL) -> Bool {
        let settings = settings()
        return installed().contains { plugin in
            guard plugin.enabled, plugin.manifest.can(.resolve) else { return false }
            let values = PluginRunner.values(of: plugin.manifest, settings: settings[plugin.id] ?? [:]).mapValues(\.text)
            return plugin.manifest.linkID(in: url, values: values) != nil
        }
    }
}

/// Where plugins are kept: repositories, installed manifests and settings in the (synced) Keychain, scripts as
/// files named by their SHA-256 (another device, or a cleared cache, downloads the same pinned script again).
public struct PluginStore: Sendable {
    let keychain: KeychainStore
    public let scriptsDirectory: URL

    public init(keychain: KeychainStore, scriptsDirectory: URL) {
        self.keychain = keychain
        self.scriptsDirectory = scriptsDirectory
    }

    public func repositories() -> [URL] {
        read([String].self, .pluginRepositories)?.compactMap(URL.init(string:)) ?? []
    }

    public func saveRepositories(_ urls: [URL]) throws {
        try write(urls.map(\.absoluteString), .pluginRepositories)
    }

    public func installed() -> [InstalledPlugin] {
        read([InstalledPlugin].self, .plugins) ?? []
    }

    public func saveInstalled(_ plugins: [InstalledPlugin]) throws {
        try write(plugins, .plugins)
    }

    public func settings() -> [String: [String: SettingValue]] {
        read([String: [String: SettingValue]].self, .pluginSettings) ?? [:]
    }

    public func saveSettings(_ settings: [String: [String: SettingValue]]) throws {
        try write(settings, .pluginSettings)
    }

    /// The installed script, if this device has it and it still matches the pinned checksum.
    public func script(for plugin: InstalledPlugin) -> String? {
        guard let data = try? Data(contentsOf: scriptURL(for: plugin.entry)),
              PluginChecksum.sha256(data) == plugin.entry.sha256.lowercased()
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func saveScript(_ script: String, for entry: PluginRepositoryIndex.Entry) throws {
        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: scriptURL(for: entry), options: .atomic)
    }

    /// Drops every script file of a plugin (all its versions).
    public func removeScripts(of pluginID: String) {
        let prefix = Self.safe(pluginID) + "-"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: scriptsDirectory.path)) ?? []
        for file in files where file.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: scriptsDirectory.appending(path: file))
        }
    }

    func scriptURL(for entry: PluginRepositoryIndex.Entry) -> URL {
        scriptsDirectory.appending(path: "\(Self.safe(entry.id))-\(entry.sha256.lowercased().prefix(16)).js")
    }

    private static func safe(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" ? $0 : "-" })
    }

    private func read<T: Decodable>(_ type: T.Type, _ key: CredentialKey) -> T? {
        guard let json = try? keychain.get(key) else { return nil }
        return try? JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func write<T: Encodable>(_ value: T, _ key: CredentialKey) throws {
        let data = try JSONEncoder().encode(value)
        try keychain.set(String(decoding: data, as: UTF8.self), for: key)
    }
}

extension PluginRepositoryIndex.Entry {
    /// A newer version of the same plugin (dotted numbers compared part by part).
    public func isNewer(than other: PluginRepositoryIndex.Entry) -> Bool {
        guard id == other.id else { return false }
        if version.compare(other.version, options: .numeric) == .orderedDescending { return true }
        return version == other.version && sha256.lowercased() != other.sha256.lowercased()
    }
}
