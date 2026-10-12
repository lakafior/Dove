import Foundation
import Security

/// Keys for every secret the app stores. Never put these in UserDefaults.
public enum CredentialKey: String, Sendable, CaseIterable {
    case torBoxAPIKey
    case realDebridAPIKey
    case offcloudAPIKey
    case nzbdavURL
    case nzbdavAPIKey
    case nzbdavWebDAVUser
    case nzbdavWebDAVPassword
    case tmdbAPIKey
    /// JSON array of Stremio addon manifest URLs, in the user's order (they embed tokens).
    case stremioAddons
    /// Password of the user's AIOStreams configuration, for its Search API.
    case aioStreamsPassword
    /// JSON array of `BackendID` raw values, highest priority first. Not a secret: it lives here because the
    /// Keychain is the one store the share extension shares with the app without an App Group.
    case debridOrder
}

public enum KeychainError: Error, Sendable {
    case unexpectedStatus(OSStatus)
}

/// Generic-password Keychain wrapper.
///
/// With an `accessGroup` (`<TeamID>.net.smigi.dove.shared`, from the `keychain-access-groups` entitlement),
/// items are written there so the share extension can read them. Reads search every group the process can
/// see, so items saved before the group existed are still found; `migrateToAccessGroup()` moves them over.
public struct KeychainStore: Sendable {
    public let service: String
    public let accessGroup: String?

    public init(service: String = "app.dove.credentials", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
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
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if let accessGroup { add[kSecAttrAccessGroup as String] = accessGroup }
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecMissingEntitlement, accessGroup != nil {
            // Built without the entitlement (e.g. unsigned): keep working app-only rather than losing the key.
            add[kSecAttrAccessGroup as String] = nil
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// Rewrites every stored value so it lands in `accessGroup`. Safe to run more than once.
    public func migrateToAccessGroup() {
        guard accessGroup != nil else { return }
        for key in CredentialKey.allCases {
            if let value = try? get(key) { try? set(value, for: key) }
        }
    }

    private func baseQuery(_ key: CredentialKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
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

    /// Every configured library backend, from the Keychain. Shared by the app and the share extension.
    public static func backends(from keychain: KeychainStore) -> [any LibraryBackend] {
        var list: [any LibraryBackend] = []
        if let key = try? keychain.get(.realDebridAPIKey), !key.isEmpty {
            list.append(RealDebridBackend(apiKey: key))
        }
        if let key = try? keychain.get(.torBoxAPIKey), !key.isEmpty {
            list.append(TorBoxBackend(apiKey: key))
        }
        if let key = try? keychain.get(.offcloudAPIKey), !key.isEmpty {
            list.append(OffcloudBackend(apiKey: key))
        }
        // TODO(stage-3): nzbdav (URL, API key, WebDAV user and password).
        return list
    }

    public static let debrids = BackendID.allCases.filter { !$0.isUsenet }

    /// The user's debrid priority; services missing from the stored list are appended in default order.
    public static func debridOrder(from keychain: KeychainStore) -> [BackendID] {
        let stored = (try? keychain.get(.debridOrder))
            .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }?
            .compactMap(BackendID.init(rawValue:)) ?? []
        return stored.filter(debrids.contains) + debrids.filter { !stored.contains($0) }
    }

    public static func saveDebridOrder(_ order: [BackendID], to keychain: KeychainStore) {
        guard let data = try? JSONEncoder().encode(order.map(\.rawValue)) else { return }
        try? keychain.set(String(decoding: data, as: UTF8.self), for: .debridOrder)
    }
}
