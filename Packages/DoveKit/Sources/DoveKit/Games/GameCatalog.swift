import Foundation

/// Another game source the app plugs in beside IGDB and Wikidata: plugins with game `metadata`
/// (`PluginGameCatalog`). Games carry the catalog's ID in `id` (`plugin:<id>:…`).
public protocol GameCatalog: Sendable {
    /// Shown in rows and errors: the plugin's name.
    var name: String { get }
    func games(matching query: String) async throws -> [GameSummary]
}

/// A game from a plugin's `metadata` for Games (`docs/plugins.md`, `Game`).
struct PluginGame: Decodable {
    var id: String
    var title: String
    var year: Int?
    var platforms: [GamePlatform]
    var cover: URL?
    var summary: String?
    var genres: [String]
    var alternativeNames: [String]
    var type: String?
    var link: URL?

    enum CodingKeys: String, CodingKey {
        case id, title, name, year, platform, platforms, cover, summary, description, genres, aliases, type, link
        case alternativeNames = "alternative_names"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLenientString(.id)
        title = try (try? c.decode(String.self, forKey: .title)) ?? c.decode(String.self, forKey: .name)
        year = c.decodeLenientInt64(.year).map(Int.init)
        let one = (try? c.decodeIfPresent(String.self, forKey: .platform)).flatMap { $0 }
        let names = (try? c.decodeIfPresent([String].self, forKey: .platforms)).flatMap { $0 } ?? one.map { [$0] } ?? []
        platforms = names.compactMap(GamePlatform.init(anyName:)).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        cover = c.decodeLenientURL(.cover)
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)).flatMap { $0 }
            ?? (try? c.decodeIfPresent(String.self, forKey: .description)).flatMap { $0 }
        genres = (try? c.decodeIfPresent([String].self, forKey: .genres)).flatMap { $0 } ?? []
        alternativeNames = (try? c.decodeIfPresent([String].self, forKey: .alternativeNames)).flatMap { $0 }
            ?? (try? c.decodeIfPresent([String].self, forKey: .aliases)).flatMap { $0 } ?? []
        // `game`, `dlc`, `expansion`, `mod`, `compilation`… in any case: shown like IGDB's ("DLC", "Mod").
        type = (try? c.decodeIfPresent(String.self, forKey: .type)).flatMap { $0 }.map { type in
            switch type.lowercased() {
            case "game", "main", "main game": "Main Game"
            case "dlc": "DLC"
            default: type.capitalized
            }
        }
        link = c.decodeLenientURL(.link)
    }

    func summary(plugin: String) -> GameSummary {
        GameSummary(
            id: "plugin:\(plugin):\(id)", title: title, year: year, platforms: platforms, cover: cover, summary: summary,
            genres: genres, alternativeNames: alternativeNames, type: type, link: link
        )
    }
}

extension GamePlatform {
    /// A platform as a plugin may name it: Dove's own (`snes`, "SNES"), a service's ("Super Nintendo Entertainment
    /// System"), or a marker ("PS2", "Nintendo 64").
    public init?(anyName name: String) {
        let text = name.trimmingCharacters(in: .whitespaces)
        if let own = GamePlatform.allCases.first(where: {
            $0.rawValue.caseInsensitiveCompare(text) == .orderedSame || $0.displayName.caseInsensitiveCompare(text) == .orderedSame
        }) {
            self = own
        } else if let service = GamePlatform(serviceName: text) {
            self = service
        } else if let marked = GamePlatform(releaseName: text) {
            self = marked
        } else {
            return nil
        }
    }
}

extension PluginRunner {
    /// Game metadata: `metadata({query, category: "games"})` answers games (`docs/plugins.md`, `Game`).
    public func games(_ plugin: PluginManifest, script: String, settings: [String: SettingValue], query: String) async throws -> [GameSummary] {
        let json = try await call(plugin, script: script, settings: settings, function: "metadata", argument: [
            "query": query, "category": SearchCategory.games.rawValue,
        ])
        return try decodeList(PluginGame.self, json).map { $0.summary(plugin: plugin.id) }
    }
}

/// A plugin with game `metadata` as a game source beside IGDB and Wikidata.
public struct PluginGameCatalog: GameCatalog {
    public let call: PluginCall
    let transport: any HTTPTransport

    public init(call: PluginCall, transport: any HTTPTransport = URLSession.shared) {
        self.call = call
        self.transport = transport
    }

    public var name: String { call.manifest.name }

    public func games(matching query: String) async throws -> [GameSummary] {
        try await PluginRunner(transport: transport).games(call.manifest, script: call.script, settings: call.settings, query: query)
    }
}
