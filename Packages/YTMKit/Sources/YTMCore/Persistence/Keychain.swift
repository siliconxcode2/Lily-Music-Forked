import Foundation
import os
import Security

/// Secrets (sign-in cookies, the Last.fm session, the user's proxy) as device-only generic passwords.
enum Keychain {
    private static let service = "Lily"
    private static let log = Logger(subsystem: "Lily", category: "Keychain")

    private static func query(_ key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
    }

    static func data(for key: String) -> Data? {
        var query = query(key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Stores `data` under `key`, or deletes the item when `data` is nil. Returns false on failure, which is also
    /// logged, as otherwise it shows only at the next launch.
    @discardableResult
    static func set(_ data: Data?, for key: String) -> Bool {
        let query = query(key)
        var status: OSStatus
        if let data {
            // Readable after first unlock, so songs resolve on the lock screen, and
            // never restored to another device from a backup.
            let update: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound { status = SecItemAdd(query.merging(update) { $1 } as CFDictionary, nil) }
        } else {
            status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { status = errSecSuccess }
        }
        if status != errSecSuccess { log.error("Keychain item \(key, privacy: .public) not saved or deleted: \(status, privacy: .public)") }
        return status == errSecSuccess
    }
}
