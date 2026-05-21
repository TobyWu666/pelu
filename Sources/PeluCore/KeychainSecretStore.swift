import Foundation
#if canImport(Security)
import Security
#endif

/// Thin wrapper around the Apple Keychain for storing per-account string secrets.
///
/// On Apple platforms with `Security.framework`, secrets persist across app
/// launches and reinstalls (per the OS rules). On unsupported platforms the
/// store operates in-memory so tests still run.
public final class KeychainSecretStore: @unchecked Sendable {
    public enum StoreError: Error {
        case unhandled(OSStatus)
        case invalidUTF8
    }

    /// `service` namespaces the keychain item to this app. Use a stable, app-wide
    /// constant (e.g. the bundle id).
    public let service: String

    public init(service: String) {
        self.service = service
    }

    /// Read the stored secret for `account`. Returns nil if no item exists.
    public func get(account: String) throws -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError.unhandled(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw StoreError.invalidUTF8
        }
        return value
        #else
        return inMemory[account]
        #endif
    }

    /// Write or replace the secret for `account`.
    public func set(_ value: String, account: String) throws {
        #if canImport(Security)
        guard let data = value.data(using: .utf8) else { throw StoreError.invalidUTF8 }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw StoreError.unhandled(updateStatus) }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        // Pin to this device only — never sync the macId UUID via iCloud
        // Keychain, otherwise two Macs would share the same identity and
        // their CloudKit records would clobber each other.
        addQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw StoreError.unhandled(addStatus) }
        #else
        inMemory[account] = value
        #endif
    }

    /// Remove any stored secret for `account`. Idempotent.
    public func remove(account: String) throws {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw StoreError.unhandled(status)
        #else
        inMemory.removeValue(forKey: account)
        #endif
    }

    #if !canImport(Security)
    private var inMemory: [String: String] = [:]
    #endif
}

