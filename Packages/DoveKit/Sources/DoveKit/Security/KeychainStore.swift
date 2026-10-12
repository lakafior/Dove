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
}

public enum KeychainError: Error, Sendable {
    case unexpectedStatus(OSStatus)
}

/// Generic-password Keychain wrapper.
/// TODO(share-extension): add a shared `kSecAttrAccessGroup` once the extension target exists.
public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String = "app.dove.credentials") {
        self.service = service
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
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(baseQuery(key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
            return
        }

        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
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
