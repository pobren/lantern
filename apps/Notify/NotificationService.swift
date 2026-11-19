// JMAP Connect's notification extension. iOS wakes it for each instant alert from our relay, before the alert
// shows. It fetches the newest email from Fastmail with the token on this device and swaps "New mail" for the
// sender and subject. If anything goes wrong or takes too long, the plain "New mail" alert shows instead.

import Foundation
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let c = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        lock.lock()
        handler = contentHandler
        content = c
        lock.unlock()
        let info = request.content.userInfo
        Task {
            await NewMail.fill(c, info: info)
            self.finish()
        }
    }

    override func serviceExtensionTimeWillExpire() { finish() }

    private func finish() {
        lock.lock()
        let h = handler, c = content
        handler = nil
        lock.unlock()
        if let h, let c { h(c) }
    }
}

enum NewMail {
    static func fill(_ c: UNMutableNotificationContent, info: [AnyHashable: Any]) async {
        guard let relayId = info["s"] as? String, var r = PushRecords.all().first(where: { $0.relayId == relayId }) else { return }
        c.threadIdentifier = r.accountId
        c.categoryIdentifier = "newMail"   // Archive and Mark as read buttons (AlertActions in the app)
        // The notice itself is encrypted for this device. If it's here and opens, it's really from Fastmail.
        if let e = info["e"] as? String, let data = Data(base64Encoded: e), let key = try? r.privateKey() {
            guard (try? PushCrypto.decrypt(data, key: key, auth: r.auth)) != nil else { return }
        }
        guard let newest = try? await newestEmail(r) else { return }
        // The unread count on the icon: this account's new count plus the last one seen for each other account.
        if r.badge ?? true, let n = newest.unread {
            r.unread = n
            PushRecords.save(r)
            let others = PushRecords.all().filter { $0.accountId != r.accountId }.compactMap(\.unread).reduce(0, +)
            c.badge = NSNumber(value: n + others)
        }
        // Already shown, or old (mail that went straight to a folder we don't show, such as Spam): keep "New mail".
        if newest.id == r.lastEmail || newest.received.timeIntervalSinceNow < -15 * 60 { return }
        c.title = newest.sender
        c.body = newest.subject.isEmpty ? "(no subject)" : newest.subject
        if let folder = newest.folder { c.subtitle = "In \(folder)" }
        c.userInfo["account"] = r.accountId
        c.userInfo["email"] = newest.id
        r.lastEmail = newest.id
        PushRecords.save(r)
    }

    struct Newest { let id: String; let sender: String; let subject: String; let received: Date; let folder: String?; let unread: Int? }

    /// The newest email that isn't one of yours (Sent or Drafts), in one request to Fastmail.
    static func newestEmail(_ r: PushRecord) async throws -> Newest? {
        guard let url = URL(string: r.apiURL) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(r.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let acct = r.mailAccountId
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
            "methodCalls": [
                ["Mailbox/get", ["accountId": acct, "properties": ["name", "role", "unreadEmails"]], "m"],
                ["Email/query", ["accountId": acct, "sort": [["property": "receivedAt", "isAscending": false]], "limit": 5], "q"],
                ["Email/get", ["accountId": acct, "#ids": ["resultOf": "q", "name": "Email/query", "path": "/ids"],
                               "properties": ["from", "subject", "receivedAt", "mailboxIds"]], "g"],
            ],
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responses = root["methodResponses"] as? [[Any]] else { return nil }
        var out: [String: [String: Any]] = [:]
        for x in responses where x.count == 3 { if let id = x[2] as? String, let args = x[1] as? [String: Any] { out[id] = args } }

        var names: [String: String] = [:], roles: [String: String] = [:]
        var unread: Int?
        for m in (out["m"]?["list"] as? [[String: Any]]) ?? [] {
            guard let id = m["id"] as? String else { continue }
            names[id] = m["name"] as? String
            if let role = m["role"] as? String { roles[id] = role }
            if m["role"] as? String == "inbox" { unread = m["unreadEmails"] as? Int }
        }
        let iso = ISO8601DateFormatter()
        for e in (out["g"]?["list"] as? [[String: Any]]) ?? [] {
            let boxes = Array(((e["mailboxIds"] as? [String: Any]) ?? [:]).keys)
            if !boxes.isEmpty && boxes.allSatisfy({ roles[$0] == "sent" || roles[$0] == "drafts" }) { continue }
            guard let id = e["id"] as? String else { continue }
            let from = (e["from"] as? [[String: Any]])?.first
            let name = (from?["name"] as? String)?.trimmingCharacters(in: .whitespaces)
            let sender = (name?.isEmpty == false ? name : nil) ?? (from?["email"] as? String) ?? "New mail"
            let received = (e["receivedAt"] as? String).flatMap { iso.date(from: $0) } ?? Date()
            let inInbox = boxes.contains { roles[$0] == "inbox" }
            let folder = inInbox ? nil : boxes.compactMap { names[$0] }.first
            return Newest(id: id, sender: sender, subject: e["subject"] as? String ?? "", received: received, folder: folder, unread: unread)
        }
        return nil
    }
}
