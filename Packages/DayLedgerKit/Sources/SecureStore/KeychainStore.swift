import Foundation
import Security

public enum KeychainError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
}

/// Generic-password Keychain storage.
///
/// By default items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so background location
/// wake-ups can refresh tokens while the phone is locked, and nothing syncs to iCloud
/// or is restored onto another device.
///
/// A `synchronizable` store (used only for end-to-end sync keys) keeps items in iCloud Keychain,
/// so the user's other devices receive them. iCloud Keychain is end-to-end encrypted by Apple.
public final class KeychainStore: SecureStoring, @unchecked Sendable {
    private let service: String
    private let synchronizable: Bool

    public init(service: String = "app.dayledger.secure", synchronizable: Bool = false) {
        self.service = service
        self.synchronizable = synchronizable
    }

    /// The service of the iCloud-synchronised store holding sync keys.
    public static let syncKeyService = "app.dayledger.synckeys"

    private var accessibility: CFString {
        synchronizable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    /// The default store's queries are unchanged from earlier versions (no synchronizable
    /// attribute), so existing items keep matching exactly as before.
    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = true
        }
        return query
    }

    private func query(for key: String) -> [String: Any] {
        var query = baseQuery()
        query[kSecAttrAccount as String] = key
        return query
    }

    public func data(for key: String) throws -> Data? {
        var query = query(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    public func set(_ data: Data, for key: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
        ]
        let status = SecItemUpdate(query(for: key) as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query(for: key)
            add.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func remove(_ key: String) throws {
        let status = SecItemDelete(query(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func removeAll() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
