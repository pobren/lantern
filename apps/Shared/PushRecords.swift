// Instant alerts: what this device needs to receive them for each account, kept in a Keychain group shared with
// the notification extension (which wakes for each alert and fetches the sender and subject from Fastmail).

import Foundation
import Security
import CryptoKit

struct PushRecord: Codable {
    var accountId: String       // the app's own id for the account
    var label: String
    var apiURL: String          // Fastmail's JMAP address and the mail account, so the extension needs one request
    var mailAccountId: String
    var token: String           // the Fastmail API token (also in the app's own Keychain item)
    var relayId: String
    var relaySecret: String
    var subscriptionId: String
    var key: Data               // this device's private key for the encrypted notices
    var auth: Data
    var expires: Date
    var device: String
    var live = false
    var lastEmail: String?
    var unread: Int?            // this account's unread inbox count when the last alert came in
    var badge: Bool?            // the app's "unread count on the app icon" setting


    func privateKey() throws -> P256.KeyAgreement.PrivateKey { try P256.KeyAgreement.PrivateKey(rawRepresentation: key) }
}

enum PushRecords {
    private static let service = "dev.paulobrien.lantern.push"
    /// "<Team ID>.dev.paulobrien.lantern.shared", from Info.plist (set from the build's App ID prefix).
    static var group: String? { Bundle.main.object(forInfoDictionaryKey: "JCKeychainGroup") as? String }

    private static func base(_ account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { q[kSecAttrAccount as String] = account }
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    static func save(_ r: PushRecord) {
        guard let data = try? JSONEncoder().encode(r) else { return }
        if SecItemUpdate(base(r.accountId) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return }
        var q = base(r.accountId)
        q[kSecValueData as String] = data
        // The extension runs while the phone is locked, so the item must open after the first unlock.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func read(_ accountId: String) -> PushRecord? {
        var q = base(accountId)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(PushRecord.self, from: data)
    }

    static func all() -> [PushRecord] {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let list = out as? [Data] else { return [] }
        return list.compactMap { try? JSONDecoder().decode(PushRecord.self, from: $0) }
    }

    static func delete(_ accountId: String) {
        SecItemDelete(base(accountId) as CFDictionary)
    }
}
