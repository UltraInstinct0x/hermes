import Foundation
import Security
import Synchronization

/// Where secrets live. Production: the Keychain. Tests: `InMemorySecretStore`.
public protocol SecretStore: Sendable {
    func read(_ account: String) throws -> String?
    func write(_ value: String, account: String) throws
    func delete(_ account: String) throws
    /// Let the item be read after the first unlock (a ring or a push can start the app while the phone is locked).
    /// Items written by an older build are only readable while unlocked. A store without such a notion does nothing.
    func relaxAccess(_ account: String) throws
}

extension SecretStore {
    public func relaxAccess(_ account: String) throws {}
}

public struct SecretStoreError: Error, Sendable, Equatable {
    public let status: Int32
    public var detail: String { "keychain status \(status)" }
}

/// A fake for tests and previews. Holds values in memory only.
public final class InMemorySecretStore: SecretStore {
    private let values = Mutex<[String: String]>([:])

    public init() {}

    public func read(_ account: String) throws -> String? { values.withLock { $0[account] } }
    public func write(_ value: String, account: String) throws { values.withLock { $0[account] = value } }
    public func delete(_ account: String) throws { values.withLock { _ = $0.removeValue(forKey: account) } }

    /// Test hook: every stored account name (never the values).
    public var accounts: [String] { values.withLock { $0.keys.sorted() } }
}

/// The Keychain behind `SecretStore`. Items are generic passwords under one service, readable after the first
/// unlock since the phone started, never migrated to another device and never synced through iCloud.
public struct KeychainSecretStore: SecretStore {
    private let service: String

    /// - Parameter service: a stable name for this app's items, for example the bundle id plus `.secrets`.
    public init(service: String) { self.service = service }

    public func read(_ account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SecretStoreError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String, account: String) throws {
        try delete(account)
        var attributes = baseQuery(account)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError(status: status) }
    }

    public func relaxAccess(_ account: String) throws {
        let status = SecItemUpdate(
            baseQuery(account) as CFDictionary, [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError(status: status) }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// The two secrets the pairing flow keeps.
public enum SecretAccount {
    /// The box base URL. Not secret, but kept beside the credential so unpairing is one operation and
    /// it never lands in logs or user defaults.
    public static let boxBaseURL = "box.base-url"
    /// The R2 device token, when the BFF returned one.
    public static let deviceToken = "device.token"
}
