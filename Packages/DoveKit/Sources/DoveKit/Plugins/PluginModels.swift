import CryptoKit
import Foundation

/// The plugin API version this build runs (`docs/plugins.md`).
public enum PluginAPI {
    public static let version = 1
}

/// A plugin repository's `index.json`.
public struct PluginRepositoryIndex: Codable, Sendable, Hashable {
    public var format: String
    public var version: Int
    public var name: String?
    public var plugins: [Entry]

    public struct Entry: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var version: String
        public var summary: String?
        /// Relative to the index URL, or absolute https.
        public var script: String
        /// Hex SHA-256 of the script file.
        public var sha256: String
        public var api: Int
        public var adult: Bool?

        public init(id: String, name: String, version: String, summary: String? = nil, script: String, sha256: String, api: Int, adult: Bool? = nil) {
            self.id = id
            self.name = name
            self.version = version
            self.summary = summary
            self.script = script
            self.sha256 = sha256
            self.api = api
            self.adult = adult
        }

        /// The script's URL against the index's.
        public func scriptURL(relativeTo index: URL) -> URL? {
            URL(string: script, relativeTo: index)?.absoluteURL
        }

        /// This build can run it.
        public var isSupported: Bool { api == PluginAPI.version }
    }
}

/// What a script declares about itself (`plugin.manifest`).
public struct PluginManifest: Codable, Sendable, Hashable {
    public enum Capability: String, Codable, Sendable, CaseIterable {
        case metadata, search, resolve
    }

    public var id: String
    public var name: String
    public var version: String
    public var api: Int
    public var capabilities: [Capability]
    /// `SearchCategory` raw values.
    public var categories: [SearchCategory]
    /// Hosts `dove.fetch` may reach; `*.example.com` covers subdomains; `{name}` is a setting.
    public var hosts: [String]
    public var settings: [Setting]
    /// URL template for the site's own search page: `{query}` and settings.
    public var browse: String?
    /// Regular expressions over a full URL with a named group `id`; settings as `{name}`.
    public var links: [String]
    public var adult: Bool

    public struct Setting: Codable, Sendable, Hashable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            case text, secret, toggle
        }

        public var key: String
        public var title: String
        public var type: Kind
        public var required: Bool
        public var help: String?
        public var `default`: SettingValue?

        public var id: String { key }

        enum CodingKeys: String, CodingKey { case key, title, type, required, help, `default` }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? key
            type = try c.decodeIfPresent(Kind.self, forKey: .type) ?? .text
            required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
            help = try c.decodeIfPresent(String.self, forKey: .help)
            `default` = try c.decodeIfPresent(SettingValue.self, forKey: .default)
        }

        public init(key: String, title: String, type: Kind, required: Bool = false, help: String? = nil, default value: SettingValue? = nil) {
            self.key = key
            self.title = title
            self.type = type
            self.required = required
            self.help = help
            self.default = value
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, version, api, capabilities, categories, hosts, settings, browse, links, adult
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0"
        api = try c.decodeIfPresent(Int.self, forKey: .api) ?? PluginAPI.version
        // Unknown capabilities and categories (a newer API's) are skipped, not fatal.
        capabilities = ((try? c.decodeIfPresent([String].self, forKey: .capabilities)) ?? []).compactMap(Capability.init(rawValue:))
        categories = ((try? c.decodeIfPresent([String].self, forKey: .categories)) ?? []).compactMap(SearchCategory.init(rawValue:))
        hosts = try c.decodeIfPresent([String].self, forKey: .hosts) ?? []
        settings = try c.decodeIfPresent([Setting].self, forKey: .settings) ?? []
        browse = try c.decodeIfPresent(String.self, forKey: .browse)
        links = try c.decodeIfPresent([String].self, forKey: .links) ?? []
        adult = try c.decodeIfPresent(Bool.self, forKey: .adult) ?? false
    }

    public func can(_ capability: Capability) -> Bool { capabilities.contains(capability) }
}

/// A setting's value: text (also secrets) or a toggle.
public enum SettingValue: Codable, Sendable, Hashable {
    case text(String)
    case toggle(Bool)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let flag = try? c.decode(Bool.self) { self = .toggle(flag) } else { self = .text(try c.decode(String.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let text): try c.encode(text)
        case .toggle(let flag): try c.encode(flag)
        }
    }

    /// As a template fills it in.
    public var text: String {
        switch self {
        case .text(let text): text
        case .toggle(let flag): flag ? "true" : "false"
        }
    }

    var json: Any {
        switch self {
        case .text(let text): text
        case .toggle(let flag): flag
        }
    }
}

/// An installed plugin: its index entry, verified script and manifest.
public struct InstalledPlugin: Codable, Sendable, Hashable, Identifiable {
    public var repository: URL
    public var entry: PluginRepositoryIndex.Entry
    public var manifest: PluginManifest
    public var enabled: Bool
    public var id: String { manifest.id }

    public init(repository: URL, entry: PluginRepositoryIndex.Entry, manifest: PluginManifest, enabled: Bool = true) {
        self.repository = repository
        self.entry = entry
        self.manifest = manifest
        self.enabled = enabled
    }
}

/// `{name}` placeholders in manifest strings.
public enum PluginTemplate {
    /// Replaces `{name}` with settings (and extra values such as `query`); `encode` URL-encodes the values.
    /// Nil when a placeholder has no value (a required setting left empty).
    public static func fill(_ template: String, values: [String: String], encode: Bool = false) -> String? {
        var result = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            result += rest[..<open]
            let name = String(rest[rest.index(after: open)..<close])
            // Only names are placeholders: `{32}` and `{1,3}` in a regular expression stay as they are.
            guard let first = name.first, first.isLetter, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                result += rest[open...close]
                rest = rest[rest.index(after: close)...]
                continue
            }
            guard let value = values[name], !value.isEmpty else { return nil }
            result += encode ? (value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value) : value
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    /// For regular expressions: values escaped so they match literally.
    public static func fillPattern(_ pattern: String, values: [String: String]) -> String? {
        fill(pattern, values: values.mapValues { NSRegularExpression.escapedPattern(for: $0) })
    }
}

extension CharacterSet {
    /// Unreserved characters only, so `+`, `&` and `=` in values stay data.
    static let urlQueryValueAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
}

/// Which hosts a plugin may reach, with its settings filled in.
public struct PluginHostPolicy: Sendable, Hashable {
    let exact: Set<String>
    let suffixes: [String]

    public init(hosts: [String], settings: [String: String]) {
        var exact = Set<String>()
        var suffixes: [String] = []
        for pattern in hosts {
            guard let filled = PluginTemplate.fill(pattern, values: settings) else { continue }
            // A setting may hold a whole address; keep its host.
            let host = (URL(string: filled)?.host() ?? filled).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            if host.hasPrefix("*.") { suffixes.append(String(host.dropFirst(1))) } else if !host.isEmpty { exact.insert(host) }
        }
        self.exact = exact
        self.suffixes = suffixes
    }

    public func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
        return exact.contains(host) || suffixes.contains { host.hasSuffix($0) }
    }
}

enum PluginChecksum {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
