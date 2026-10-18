import Foundation

extension CredentialKey {
    /// What an export without secrets does with the value.
    public enum Sensitivity: Sendable {
        /// Settings with nothing to hide: always exported.
        case setting
        /// A key, password or a URL with a token in it: only in exports with secrets.
        case secret
        /// Settings that carry a secret inside (indexers' API keys, Kodi's password): exported without it.
        case mixed
    }

    public var sensitivity: Sensitivity {
        switch self {
        case .torBoxAPIKey, .realDebridAPIKey, .offcloudAPIKey, .debridLinkAPIKey, .premiumizeAPIKey, .allDebridAPIKey,
             .nzbdavAPIKey, .nzbdavWebDAVUser, .nzbdavWebDAVPassword, .nzbdavFrontendKey, .tmdbAPIKey,
             .googleBooksAPIKey, .hardcoverToken, .bookProviders, .directSources,
             .stremioAddons, .aioStreamsPassword:
            .secret
        case .newznabIndexers, .kodi:
            .mixed
        case .nzbdavURL, .debridOrder, .usenetOrder, .torBoxUsenet, .torBoxPlan, .privateTrackers, .offcloudUsenet,
             .premiumizeUsenet, .preferences, .audiobookPositions, .watchlist:
            .setting
        }
    }
}

/// Dove's settings as a file, for installs iCloud Keychain does not reach (sideloaded builds signed by another
/// team, the Simulator). Like AIOStreams' export: with or without secrets. The file is plain JSON; one with
/// secrets holds every key and password, so the app says so before it is saved.
///
/// Importing merges: only what the file holds is written. Without secrets the keys already on the device stay,
/// and indexers and Kodi keep the key or password the device has for the same feed or host.
public struct SettingsBackup: Codable, Sendable, Equatable {
    public static let formatName = "dove-settings"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var includesSecrets: Bool
    /// `CredentialKey` raw value → the stored string. Unknown keys (from a newer Dove) are ignored on import.
    public var values: [String: String]

    public enum ImportError: LocalizedError, Equatable {
        case notDoveSettings
        case newerVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .notDoveSettings: "This file is not a Dove settings export."
            case .newerVersion(let version): "This export comes from a newer Dove (format \(version)). Update Dove first."
            }
        }
    }

    public struct ImportSummary: Sendable, Equatable {
        /// Keys written.
        public var applied: [CredentialKey]
        /// Indexers imported without an API key (the file had none, the device had none for that feed): left off.
        public var indexersNeedingKeys: [String]
    }

    // MARK: - Export

    public static func export(includeSecrets: Bool, now: Date = .now, read: (CredentialKey) -> String?) -> SettingsBackup {
        var values: [String: String] = [:]
        for key in CredentialKey.allCases {
            guard let value = read(key), !value.isEmpty else { continue }
            switch key.sensitivity {
            case .setting: values[key.rawValue] = value
            case .secret: if includeSecrets { values[key.rawValue] = value }
            case .mixed: values[key.rawValue] = includeSecrets ? value : withoutSecret(value, key: key)
            }
        }
        return SettingsBackup(format: formatName, version: currentVersion, exportedAt: now, includesSecrets: includeSecrets, values: values)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// "Dove settings 2026-10-16.json", "Dove settings with keys 2026-10-16.json".
    public var fileName: String {
        let day = exportedAt.formatted(.iso8601.year().month().day())
        return "Dove settings\(includesSecrets ? " with keys" : "") \(day).json"
    }

    private static func withoutSecret(_ value: String, key: CredentialKey) -> String? {
        let data = Data(value.utf8)
        switch key {
        case .newznabIndexers:
            guard var list = try? JSONDecoder().decode([NewznabIndexer].self, from: data) else { return nil }
            for index in list.indices { list[index].apiKey = "" }
            return (try? JSONEncoder().encode(list)).map { String(decoding: $0, as: UTF8.self) }
        case .kodi:
            guard var server = try? JSONDecoder().decode(KodiServer.self, from: data) else { return nil }
            server.password = ""
            return (try? JSONEncoder().encode(server)).map { String(decoding: $0, as: UTF8.self) }
        default:
            return nil
        }
    }

    // MARK: - Import

    public static func decode(_ data: Data) throws -> SettingsBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(SettingsBackup.self, from: data), backup.format == formatName else {
            throw ImportError.notDoveSettings
        }
        guard backup.version <= currentVersion else { throw ImportError.newerVersion(backup.version) }
        return backup
    }

    /// Writes the file's values. `read` gives the device's current values, for keys and passwords the file left out.
    public func apply(read: (CredentialKey) -> String?, write: (String, CredentialKey) throws -> Void) throws -> ImportSummary {
        var summary = ImportSummary(applied: [], indexersNeedingKeys: [])
        for key in CredentialKey.allCases {
            guard var value = values[key.rawValue], !value.isEmpty else { continue }
            switch key {
            case .newznabIndexers:
                guard let merged = Self.mergeIndexers(value, current: read(key), missing: &summary.indexersNeedingKeys) else { continue }
                value = merged
            case .kodi:
                guard let merged = Self.mergeKodi(value, current: read(key)) else { continue }
                value = merged
            default:
                break
            }
            try write(value, key)
            summary.applied.append(key)
        }
        return summary
    }

    /// Imported indexers without a key take the device's key for the same feed; with none they are turned off.
    private static func mergeIndexers(_ value: String, current: String?, missing: inout [String]) -> String? {
        guard var imported = try? JSONDecoder().decode([NewznabIndexer].self, from: Data(value.utf8)) else { return nil }
        guard imported.contains(where: \.apiKey.isEmpty) else { return value }
        let existing = current.flatMap { try? JSONDecoder().decode([NewznabIndexer].self, from: Data($0.utf8)) } ?? []
        for index in imported.indices where imported[index].apiKey.isEmpty {
            if let key = existing.first(where: { $0.feed == imported[index].feed && !$0.apiKey.isEmpty })?.apiKey {
                imported[index].apiKey = key
            } else {
                imported[index].enabled = false
                missing.append(imported[index].name)
            }
        }
        return (try? JSONEncoder().encode(imported)).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func mergeKodi(_ value: String, current: String?) -> String? {
        guard var imported = try? JSONDecoder().decode(KodiServer.self, from: Data(value.utf8)) else { return nil }
        guard imported.password.isEmpty else { return value }
        if
           let existing = current.flatMap({ try? JSONDecoder().decode(KodiServer.self, from: Data($0.utf8)) }),
           existing.host == imported.host {
            imported.password = existing.password
        }
        return (try? JSONEncoder().encode(imported)).map { String(decoding: $0, as: UTF8.self) }
    }
}
