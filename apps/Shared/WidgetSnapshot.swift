// What the Home Screen and Lock Screen widgets show: the unread count and the latest few inbox emails. The app saves
// it in the Keychain group it already shares with its extensions each time the inbox changes, and the widget only
// reads it, so the widget never needs your key or the network.

import Foundation
import Security

struct WidgetSnapshot: Codable {
    struct Mail: Codable, Identifiable {
        var id: String
        var account: String
        var sender: String
        var subject: String
        var date: Date
        var unread: Bool
    }
    var unread: Int
    var latest: [Mail]
    var saved: Date
}

enum WidgetStore {
    private static let service = "dev.paulobrien.lantern.widget"
    static var group: String? { Bundle.main.object(forInfoDictionaryKey: "JCKeychainGroup") as? String }

    private static func base() -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: "snapshot"]
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    static func save(_ s: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        if SecItemUpdate(base() as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return }
        var q = base()
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func read() -> WidgetSnapshot? {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
