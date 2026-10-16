import Foundation
import Testing
@testable import DoveKit

struct SettingsBackupTests {
    private let indexers: [NewznabIndexer] = [
        NewznabIndexer(id: "a", kind: .torznab, name: "Seedpool", url: URL(string: "https://jackett.example/api/v2.0/indexers/seedpool/results/torznab")!, apiKey: "JACKETT"),
        NewznabIndexer(id: "b", name: "Geek", url: URL(string: "https://api.nzbgeek.info")!, apiKey: "GEEK"),
    ]

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func store() throws -> [CredentialKey: String] {
        [
            .torBoxAPIKey: "TB-SECRET",
            .stremioAddons: #"["https://aio.example/stremio/uuid/token/manifest.json"]"#,
            .debridOrder: #"["torBox","realDebrid"]"#,
            .nzbdavURL: "https://nzbdav.example",
            .newznabIndexers: try json(indexers),
            .kodi: try json(KodiServer(host: "kodi.local", password: "pw")),
        ]
    }

    @Test func withoutSecretsKeepsSettingsAndStripsKeysInsideThem() throws {
        let values = try store()
        let backup = SettingsBackup.export(includeSecrets: false) { values[$0] }
        #expect(backup.values[CredentialKey.torBoxAPIKey.rawValue] == nil)
        #expect(backup.values[CredentialKey.stremioAddons.rawValue] == nil, "addon URLs carry tokens")
        #expect(backup.values[CredentialKey.debridOrder.rawValue] == values[.debridOrder])
        #expect(backup.values[CredentialKey.nzbdavURL.rawValue] == "https://nzbdav.example")
        let exported = try JSONDecoder().decode([NewznabIndexer].self, from: Data(backup.values[CredentialKey.newznabIndexers.rawValue]!.utf8))
        #expect(exported.map(\.name) == ["Seedpool", "Geek"])
        #expect(exported.allSatisfy { $0.apiKey.isEmpty })
        let kodi = try JSONDecoder().decode(KodiServer.self, from: Data(backup.values[CredentialKey.kodi.rawValue]!.utf8))
        #expect(kodi.host == "kodi.local" && kodi.password.isEmpty)
        let text = String(decoding: try backup.encoded(), as: UTF8.self)
        #expect(!text.contains("SECRET") && !text.contains("JACKETT") && !text.contains("token"))
    }

    @Test func withSecretsRoundTripsEverything() throws {
        let values = try store()
        let backup = SettingsBackup.export(includeSecrets: true, now: Date(timeIntervalSince1970: 1_800_000_000)) { values[$0] }
        let decoded = try SettingsBackup.decode(try backup.encoded())
        #expect(decoded == backup)
        #expect(decoded.fileName == "Dove settings with keys 2027-01-15.json")

        var written: [CredentialKey: String] = [:]
        let summary = try decoded.apply(read: { _ in nil }) { written[$1] = $0 }
        #expect(written == values)
        #expect(summary.indexersNeedingKeys.isEmpty)
    }

    @Test func importWithoutSecretsKeepsTheDeviceKeys() throws {
        let values = try store()
        let backup = SettingsBackup.export(includeSecrets: false) { values[$0] }
        // The device knows Seedpool's key and the Kodi password, but not the Geek indexer.
        var device: [CredentialKey: String] = [
            .torBoxAPIKey: "DEVICE-KEY",
            .newznabIndexers: try json([indexers[0]]),
            .kodi: try json(KodiServer(host: "kodi.local", password: "device-pw")),
        ]
        let summary = try backup.apply(read: { device[$0] }) { device[$1] = $0 }
        #expect(device[.torBoxAPIKey] == "DEVICE-KEY", "keys the file does not hold stay")
        let merged = try JSONDecoder().decode([NewznabIndexer].self, from: Data(device[.newznabIndexers]!.utf8))
        #expect(merged.map(\.apiKey) == ["JACKETT", ""])
        #expect(merged.map(\.enabled) == [true, false], "an indexer without a key is left off")
        #expect(summary.indexersNeedingKeys == ["Geek"])
        #expect(try JSONDecoder().decode(KodiServer.self, from: Data(device[.kodi]!.utf8)).password == "device-pw")
    }

    @Test func otherFilesAndNewerFormatsAreRefused() throws {
        #expect(throws: SettingsBackup.ImportError.notDoveSettings) { try SettingsBackup.decode(Data(#"{"a":1}"#.utf8)) }
        var backup = SettingsBackup.export(includeSecrets: false) { _ in nil }
        backup.version = 99
        #expect(throws: SettingsBackup.ImportError.newerVersion(99)) { try SettingsBackup.decode(try backup.encoded()) }
    }
}
