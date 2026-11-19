// API tokens live in the Mac's Keychain, never in a file or settings.

import Foundation
import Security

enum Keychain {
    private static let service = "dev.paulobrien.lantern"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func save(_ account: String, _ value: String) {
        let change: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        if SecItemUpdate(query(account) as CFDictionary, change as CFDictionary) == errSecSuccess { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// Keys kept in the person's iCloud Keychain, so removing an account (or setting up another iPhone, iPad or Mac)
/// doesn't mean making a new API token. Paul, 19 Nov: people would otherwise need a new key every time they sign
/// out, unless they'd kept a copy. iCloud Keychain is end to end encrypted; "Forget the key too" deletes it.
enum SavedKeys {
    struct Saved: Identifiable, Hashable {
        let kind: String
        let sessionURL: String
        let username: String
        var id: String { "\(kind)|\(sessionURL)|\(username)" }
    }

    private static let service = "dev.paulobrien.lantern.saved"

    private static func base() -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrSynchronizable as String: kCFBooleanTrue as Any]
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }

    static func save(_ s: Saved, token: String) {
        guard !s.username.isEmpty else { return }
        var q = base()
        q[kSecAttrAccount as String] = s.id
        let change: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        if SecItemUpdate(q as CFDictionary, change as CFDictionary) == errSecSuccess { return }
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        q[kSecAttrLabel as String] = "JMAP Connect: \(s.username)"
        SecItemAdd(q as CFDictionary, nil)
    }

    static func all() -> [Saved] {
        var q = base()
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            let parts = ((item[kSecAttrAccount as String] as? String) ?? "").components(separatedBy: "|")
            guard parts.count >= 3 else { return nil }
            return Saved(kind: parts[0], sessionURL: parts[1...(parts.count - 2)].joined(separator: "|"), username: parts[parts.count - 1])
        }
    }

    static func token(_ s: Saved) -> String? {
        var q = base()
        q[kSecAttrAccount as String] = s.id
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ s: Saved) {
        var q = base()
        q[kSecAttrAccount as String] = s.id
        SecItemDelete(q as CFDictionary)
    }
}
