import Foundation
import Security

/// Keys for every secret the app stores. Never put these in UserDefaults.
public enum CredentialKey: String, Sendable, CaseIterable {
    case torBoxAPIKey
    case realDebridAPIKey
    case offcloudAPIKey
    case debridLinkAPIKey
    case nzbdavURL
    case nzbdavAPIKey
    case nzbdavWebDAVUser
    case nzbdavWebDAVPassword
    /// nzbdav's `FRONTEND_BACKEND_API_KEY` (set in its environment): NZB downloads from history and signed
    /// `/view` links. Optional.
    case nzbdavFrontendKey
    case tmdbAPIKey
    /// JSON array of Stremio addon manifest URLs, in the user's order (they embed tokens).
    case stremioAddons
    /// Password of the user's AIOStreams configuration, for its Search API.
    case aioStreamsPassword
    /// JSON array of `BackendID` raw values, highest priority first. Not a secret: it lives here because the
    /// Keychain is the one store the share extension shares with the app without an App Group.
    case debridOrder
    /// JSON array of `BackendID` raw values: where NZBs go, highest priority first (nzbdav, TorBox, Offcloud).
    case usenetOrder
    /// "1" / "0" when the user turned TorBox Usenet on or off; unset follows the plan (`TorBoxPlanSetting.usenet`).
    /// Not a secret; shared with the extension like `debridOrder`.
    case torBoxUsenet
    /// JSON of `TorBoxPlanSetting`: the plan `user/me` reported and the one picked in Settings.
    case torBoxPlan
    /// `PrivateTrackerTarget` raw value: where private trackers' torrents go.
    case privateTrackers
    /// "1" when NZBs may go to Offcloud. Not a secret, like `torBoxUsenet`.
    case offcloudUsenet
    /// JSON array of `NewznabIndexer` (they carry API keys).
    case newznabIndexers
    /// JSON of `KodiServer` (it carries the password).
    case kodi
    /// JSON of `SyncedPreferences`: settings that are not secrets, kept here so iCloud Keychain carries them too.
    case preferences
}

public enum KeychainError: Error, Sendable {
    case unexpectedStatus(OSStatus)
}

/// Generic-password Keychain wrapper.
///
/// With an `accessGroup` (`<TeamID>.net.smigi.dove.shared`, from the `keychain-access-groups` entitlement),
/// items are written there so the share extension can read them. Reads search every group the process can
/// see, so items saved before the group existed are still found; `migrateToAccessGroup()` moves them over.
///
/// Items are written `synchronizable`: iCloud Keychain carries them, end-to-end encrypted, to the user's other
/// devices and to a fresh install (when iCloud Keychain is on; only builds signed by the same team can read
/// them). Reads and deletes match synced and device-only items alike, so older device-only items are still
/// found until `migrateToAccessGroup()` rewrites them.
public struct KeychainStore: Sendable {
    public let service: String
    public let accessGroup: String?
    public let synchronizable: Bool

    public init(service: String = "app.dove.credentials", accessGroup: String? = nil, synchronizable: Bool = true) {
        self.service = service
        self.accessGroup = accessGroup
        self.synchronizable = synchronizable
    }

    public func get(_ key: CredentialKey) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Passing nil or an empty string removes the value.
    public func set(_ value: String?, for key: CredentialKey) throws {
        // Removes the item from every group it may be in (the old app-only one included).
        let deleteStatus = SecItemDelete(baseQuery(key) as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(deleteStatus)
        }
        guard let value, !value.isEmpty else { return }

        var add = baseQuery(key)
        add[kSecValueData as String] = Data(value.utf8)
        // Synced items cannot be "this device only"; after first unlock keeps background downloads working.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrSynchronizable as String] = synchronizable
        if let accessGroup { add[kSecAttrAccessGroup as String] = accessGroup }
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecMissingEntitlement, accessGroup != nil {
            // Built without the entitlement (e.g. unsigned): keep working app-only rather than losing the key.
            add[kSecAttrAccessGroup as String] = nil
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status == errSecMissingEntitlement || status == errSecParam, synchronizable {
            // No iCloud Keychain for this process (unsigned test runs): keep the value on the device.
            add[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// Rewrites every stored value so it lands in `accessGroup`, synchronizable. Safe to run more than once.
    public func migrateToAccessGroup() {
        for key in CredentialKey.allCases {
            if let value = try? get(key) { try? set(value, for: key) }
        }
    }

    private func baseQuery(_ key: CredentialKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            // Match synced and device-only copies, so reads find old items and deletes leave no duplicate.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
    }
}

/// Where the app and its extensions meet: the shared Keychain group and the settings both read.
public enum SharedConfiguration {
    /// `DoveKeychainGroup` in the target's Info.plist, set from `$(AppIdentifierPrefix)` at build time.
    public static var keychainGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "DoveKeychainGroup") as? String
    }

    public static func keychain() -> KeychainStore {
        KeychainStore(accessGroup: keychainGroup)
    }

    /// `DoveAppGroup` in the Info.plist: the container the app and the Files extension share.
    public static var appGroupContainer: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "DoveAppGroup") as? String)
            .flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    /// Learned and user-set item kinds (`KindOverrides`); the Files extension reads them to hide adult items.
    public static var kindsURL: URL {
        (appGroupContainer ?? .applicationSupportDirectory.appending(path: "Dove")).appending(path: "Library/kinds.json")
    }

    /// Every configured library backend, from the Keychain. Shared by the app and the share extension.
    public static func backends(from keychain: KeychainStore) -> [any LibraryBackend] {
        var list: [any LibraryBackend] = []
        if let key = try? keychain.get(.realDebridAPIKey), !key.isEmpty {
            list.append(RealDebridBackend(apiKey: key))
        }
        let torBoxKey = (try? keychain.get(.torBoxAPIKey)) ?? ""
        let debridLinkKey = (try? keychain.get(.debridLinkAPIKey)) ?? ""
        let torBoxPlan = torBoxPlan(from: keychain)
        let privateServices = privateTrackers(from: keychain).services(
            debridLink: !debridLinkKey.isEmpty,
            torBox: !torBoxKey.isEmpty && torBoxPlan.plan?.seedingTime != nil
        )
        if !torBoxKey.isEmpty {
            list.append(TorBoxBackend(
                apiKey: torBoxKey,
                usenet: torBoxPlan.usenet(toggle: try? keychain.get(.torBoxUsenet)),
                takesPrivateTorrents: privateServices.contains(.torBox)
            ))
        }
        if let key = try? keychain.get(.offcloudAPIKey), !key.isEmpty {
            list.append(OffcloudBackend(apiKey: key, usenet: (try? keychain.get(.offcloudUsenet)) == "1"))
        }
        if !debridLinkKey.isEmpty {
            list.append(DebridLinkBackend(apiKey: debridLinkKey, takesPrivateTorrents: privateServices.contains(.debridLink)))
        }
        if let nzbdav = nzbdav(from: keychain) {
            list.append(nzbdav)
        }
        return list
    }

    /// nzbdav, when its URL, API key and WebDAV login are all set.
    static func nzbdav(from keychain: KeychainStore) -> NzbdavBackend? {
        let value = { (key: CredentialKey) in (try? keychain.get(key))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        guard let url = URL(string: value(.nzbdavURL)), url.scheme == "https" || url.scheme == "http",
              !value(.nzbdavAPIKey).isEmpty, !value(.nzbdavWebDAVUser).isEmpty, !value(.nzbdavWebDAVPassword).isEmpty
        else { return nil }
        return NzbdavBackend(
            baseURL: url,
            apiKey: value(.nzbdavAPIKey),
            webDAVUser: value(.nzbdavWebDAVUser),
            webDAVPassword: value(.nzbdavWebDAVPassword),
            frontendKey: value(.nzbdavFrontendKey)
        )
    }

    public static let debrids = BackendID.allCases.filter { !$0.isUsenet }

    public static func torBoxPlan(from keychain: KeychainStore) -> TorBoxPlanSetting {
        (try? keychain.get(.torBoxPlan))
            .flatMap { try? JSONDecoder().decode(TorBoxPlanSetting.self, from: Data($0.utf8)) } ?? TorBoxPlanSetting()
    }

    public static func saveTorBoxPlan(_ setting: TorBoxPlanSetting, to keychain: KeychainStore) {
        guard let data = try? JSONEncoder().encode(setting) else { return }
        try? keychain.set(setting == TorBoxPlanSetting() ? nil : String(decoding: data, as: UTF8.self), for: .torBoxPlan)
    }

    public static func privateTrackers(from keychain: KeychainStore) -> PrivateTrackerTarget {
        (try? keychain.get(.privateTrackers)).flatMap(PrivateTrackerTarget.init(rawValue:)) ?? .automatic
    }

    /// The user's debrid priority; services missing from the stored list are appended in default order.
    public static func debridOrder(from keychain: KeychainStore) -> [BackendID] {
        let stored = stored(.debridOrder, in: keychain)
        return stored.filter(debrids.contains) + debrids.filter { !stored.contains($0) }
    }

    public static func saveDebridOrder(_ order: [BackendID], to keychain: KeychainStore) {
        save(order, as: .debridOrder, to: keychain)
    }

    /// Services that can take NZBs (TorBox with Usenet on or a Pro plan, Offcloud with its toggle on).
    public static let usenetServices: [BackendID] = [.nzbdav, .torBox, .offcloud]

    /// The user's NZB priority. Until it is set: nzbdav, then the debrids in their own order.
    public static func usenetOrder(from keychain: KeychainStore) -> [BackendID] {
        let fallback = [.nzbdav] + debridOrder(from: keychain).filter(usenetServices.contains)
        let stored = stored(.usenetOrder, in: keychain).filter(usenetServices.contains)
        return stored + fallback.filter { !stored.contains($0) }
    }

    public static func saveUsenetOrder(_ order: [BackendID], to keychain: KeychainStore) {
        save(order, as: .usenetOrder, to: keychain)
    }

    private static func stored(_ key: CredentialKey, in keychain: KeychainStore) -> [BackendID] {
        (try? keychain.get(key))
            .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }?
            .compactMap(BackendID.init(rawValue:)) ?? []
    }

    private static func save(_ order: [BackendID], as key: CredentialKey, to keychain: KeychainStore) {
        guard let data = try? JSONEncoder().encode(order.map(\.rawValue)) else { return }
        try? keychain.set(String(decoding: data, as: UTF8.self), for: key)
    }
}
