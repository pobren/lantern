// JMAP Connect on Apple Watch: the accounts the iPhone handed over, and a small JMAP client for the inbox.
// Used by the Watch app and its complication. The tokens sit in the Watch's own Keychain, shared by the two.

import Foundation
import Security

struct WatchAccount: Codable, Hashable, Identifiable {
    let id: String
    let label: String
    let session: String
}

struct WatchAddress: Codable, Hashable {
    var name: String?
    var email: String
    var display: String { (name?.isEmpty == false ? name : nil) ?? email }
}

struct WatchEmail: Codable, Hashable, Identifiable {
    let id: String
    var account: String = ""
    let threadId: String?
    let mailboxIds: [String: Bool]?
    var keywords: [String: Bool]?
    let from: [WatchAddress]?
    let to: [WatchAddress]?
    let cc: [WatchAddress]?
    let replyTo: [WatchAddress]?
    let subject: String?
    let preview: String?
    let receivedAt: String
    let messageId: [String]?
    let references: [String]?

    var key: String { account + "/" + id }
    var sender: WatchAddress { from?.first ?? WatchAddress(name: "Unknown sender", email: "") }
    var title: String { (subject?.isEmpty == false ? subject : nil) ?? "(No subject)" }
    var unread: Bool { keywords?["$seen"] != true }
    var starred: Bool { keywords?["$flagged"] == true }
    var date: Date {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: receivedAt) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: receivedAt) ?? .distantPast
    }

    static let properties = ["id", "threadId", "mailboxIds", "keywords", "from", "to", "cc", "replyTo", "subject", "preview",
                             "receivedAt", "messageId", "references"]
}

/// The Watch's list of accounts and their tokens.
enum WatchAccounts {
    static let group: String? = Bundle.main.object(forInfoDictionaryKey: "JCKeychainGroup") as? String
    private static let service = "dev.paulobrien.lantern.watch"
    private static let listKey = "watch.accounts"
    private static let sampleKey = "watch.sample"

    static var all: [WatchAccount] {
        guard let data = read("list"), let list = try? JSONDecoder().decode([WatchAccount].self, from: data) else { return [] }
        return list
    }

    static var sample: Bool { read("sample") != nil }

    static func token(_ id: String) -> String? { read("token." + id).flatMap { String(data: $0, encoding: .utf8) } }

    /// Saves what the iPhone sent: accounts, tokens and whether it's showing sample mail.
    static func take(_ context: [String: Any]) {
        let given = (context["accounts"] as? [[String: String]]) ?? []
        var list: [WatchAccount] = []
        for a in given {
            guard let id = a["id"], let token = a["token"], let session = a["session"] else { continue }
            write("token." + id, Data(token.utf8))
            list.append(WatchAccount(id: id, label: a["label"] ?? "Fastmail", session: session))
        }
        for old in all where !list.contains(where: { $0.id == old.id }) { delete("token." + old.id) }
        if let data = try? JSONEncoder().encode(list) { write("list", data) }
        if context["sample"] as? Bool == true { write("sample", Data("1".utf8)) } else { delete("sample") }
    }

    // Keychain, shared between the Watch app and its complication.
    private static func query(_ key: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        if let group, !group.hasPrefix("$(") { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    private static func write(_ key: String, _ value: Data) {
        if SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: value] as CFDictionary) == errSecSuccess { return }
        var q = query(key)
        q[kSecValueData as String] = value
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    private static func read(_ key: String) -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func delete(_ key: String) { SecItemDelete(query(key) as CFDictionary) }
}

enum WatchError: LocalizedError {
    case signIn, server(Int), failed(String)
    var errorDescription: String? {
        switch self {
        case .signIn: return "Fastmail didn't accept the token. Open JMAP Connect on your iPhone."
        case .server(let c): return "Fastmail answered with an error (\(c))."
        case .failed(let why): return why
        }
    }
}

/// Just enough JMAP for the Watch: the inbox, one email's text, flags, archive and a short reply.
final class WatchJMAP: @unchecked Sendable {
    let account: WatchAccount
    private let token: String
    private var api: URL?
    private var accountId: String?
    private var boxes: [String: String] = [:]   // role -> mailbox id
    private let http: URLSession

    init?(_ account: WatchAccount) {
        guard let token = WatchAccounts.token(account.id) else { return nil }
        self.account = account
        self.token = token
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 25
        c.waitsForConnectivity = false
        http = URLSession(configuration: c)
    }

    private func request(_ url: URL, body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { r.httpMethod = "POST"; r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    private func connect() async throws {
        guard let url = URL(string: account.session) else { throw WatchError.failed("Bad server address") }
        let (data, res) = try await http.data(for: request(url))
        let code = (res as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw WatchError.signIn }
        guard code == 200, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apiUrl = root["apiUrl"] as? String,
              let acc = (root["primaryAccounts"] as? [String: String])?["urn:ietf:params:jmap:mail"] else { throw WatchError.server(code) }
        api = URL(string: apiUrl)
        accountId = acc
        let r = try await call([["Mailbox/get", ["accountId": acc, "properties": ["id", "role", "unreadEmails"]], "m"]])
        for m in (r["m"]?["list"] as? [[String: Any]]) ?? [] {
            if let role = m["role"] as? String, let id = m["id"] as? String { boxes[role] = id }
        }
    }

    private func call(_ calls: [[Any]], submission: Bool = false) async throws -> [String: [String: Any]] {
        if api == nil, accountId == nil { try await connect() }
        guard let api else { throw WatchError.failed("No server") }
        var using = ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"]
        if submission { using.append("urn:ietf:params:jmap:submission") }
        let body = try JSONSerialization.data(withJSONObject: ["using": using, "methodCalls": calls])
        let (data, res) = try await http.data(for: request(api, body: body))
        let code = (res as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw WatchError.signIn }
        guard code == 200, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responses = root["methodResponses"] as? [[Any]] else { throw WatchError.server(code) }
        var out: [String: [String: Any]] = [:]
        for r in responses where r.count == 3 {
            guard let name = r[0] as? String, let args = r[1] as? [String: Any], let id = r[2] as? String else { continue }
            if name == "error" { throw WatchError.failed(args["description"] as? String ?? (args["type"] as? String ?? "Error")) }
            out[id] = args
        }
        return out
    }

    private func ready() async throws -> String {
        if accountId == nil { try await connect() }
        guard let accountId else { throw WatchError.failed("No account") }
        return accountId
    }

    /// The newest emails in the inbox, one per conversation, and the inbox's unread count.
    func inbox(limit: Int = 30) async throws -> (emails: [WatchEmail], unread: Int) {
        let acc = try await ready()
        guard let inbox = boxes["inbox"] else { throw WatchError.failed("No inbox") }
        let r = try await call([
            ["Email/query", ["accountId": acc, "filter": ["inMailbox": inbox], "sort": [["property": "receivedAt", "isAscending": false]],
                             "collapseThreads": true, "limit": limit], "q"],
            ["Email/get", ["accountId": acc, "#ids": ["resultOf": "q", "name": "Email/query", "path": "/ids"],
                           "properties": WatchEmail.properties], "g"],
            ["Mailbox/get", ["accountId": acc, "ids": [inbox], "properties": ["unreadEmails"]], "m"],
        ])
        let list = (r["g"]?["list"] as? [[String: Any]]) ?? []
        let data = try JSONSerialization.data(withJSONObject: list)
        var emails = try JSONDecoder().decode([WatchEmail].self, from: data)
        for i in emails.indices { emails[i].account = account.id }
        let unread = ((r["m"]?["list"] as? [[String: Any]])?.first?["unreadEmails"] as? Int) ?? emails.filter(\.unread).count
        return (emails, unread)
    }

    /// The inbox's unread count only, for the complication.
    func unread() async throws -> Int {
        let acc = try await ready()
        guard let inbox = boxes["inbox"] else { return 0 }
        let r = try await call([["Mailbox/get", ["accountId": acc, "ids": [inbox], "properties": ["unreadEmails"]], "m"]])
        return ((r["m"]?["list"] as? [[String: Any]])?.first?["unreadEmails"] as? Int) ?? 0
    }

    /// The email's words as plain text (the Watch has no room for layout).
    func text(_ id: String) async throws -> String {
        let acc = try await ready()
        let r = try await call([["Email/get", ["accountId": acc, "ids": [id], "properties": ["textBody", "htmlBody", "bodyValues"],
                                               "fetchTextBodyValues": true, "fetchHTMLBodyValues": true, "maxBodyValueBytes": 40_000], "b"]])
        guard let e = (r["b"]?["list"] as? [[String: Any]])?.first else { return "" }
        let values = (e["bodyValues"] as? [String: [String: Any]]) ?? [:]
        let text = ((e["textBody"] as? [[String: Any]]) ?? []).compactMap { p -> String? in
            guard let id = p["partId"] as? String else { return nil }
            let v = values[id]?["value"] as? String
            return (p["type"] as? String)?.lowercased() == "text/html" ? v.map(Self.plain) : v
        }.joined(separator: "\n\n")
        return Self.tidy(text)
    }

    static func plain(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<br[^>]*>|</p>|</div>|</tr>|</h[1-6]>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<style[\\s\\S]*?</style>|<script[\\s\\S]*?</script>", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (a, b) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&rsquo;", "’"), ("&lsquo;", "‘")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s
    }

    /// Drops quoted earlier emails and long runs of blank lines.
    static func tidy(_ text: String) -> String {
        var out: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(">") { continue }
            if t.isEmpty && (out.last?.isEmpty ?? true) { continue }
            out.append(t)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func set(_ id: String, keyword: String, _ on: Bool) async throws {
        let acc = try await ready()
        _ = try await call([["Email/set", ["accountId": acc, "update": [id: ["keywords/\(keyword)": on ? true : NSNull()]]], "s"]])
    }

    /// Archive takes the email out of the Inbox and files it in Archive (so labels elsewhere stay).
    func archive(_ id: String) async throws {
        let acc = try await ready()
        guard let inbox = boxes["inbox"] else { return }
        var patch: [String: Any] = ["mailboxIds/\(inbox)": NSNull(), "keywords/$seen": true]
        if let archive = boxes["archive"] { patch["mailboxIds/\(archive)"] = true }
        _ = try await call([["Email/set", ["accountId": acc, "update": [id: patch]], "s"]])
    }

    func delete(_ id: String) async throws {
        let acc = try await ready()
        guard let trash = boxes["trash"] else { return }
        _ = try await call([["Email/set", ["accountId": acc, "update": [id: ["mailboxIds": [trash: true], "keywords/$seen": true]]], "s"]])
    }

    /// A short plain text reply, from the address the email was sent to when that's one of yours.
    func reply(to e: WatchEmail, text: String) async throws {
        let acc = try await ready()
        guard let drafts = boxes["drafts"], let sent = boxes["sent"] else { throw WatchError.failed("No Drafts or Sent folder") }
        let r = try await call([["Identity/get", ["accountId": acc], "i"]], submission: true)
        let ids = (r["i"]?["list"] as? [[String: Any]]) ?? []
        let wrote = Set(((e.to ?? []) + (e.cc ?? [])).map { $0.email.lowercased() })
        let identity = ids.first { wrote.contains(($0["email"] as? String ?? "").lowercased()) } ?? ids.first
        guard let identity, let identityId = identity["id"] as? String, let from = identity["email"] as? String,
              !from.contains("*") else { throw WatchError.failed("No address to send from") }
        let to = (e.replyTo?.isEmpty == false ? e.replyTo! : [e.sender]).map { ["name": $0.name ?? "", "email": $0.email] }
        let subject = e.title.lowercased().hasPrefix("re:") ? e.title : "Re: \(e.title)"
        var email: [String: Any] = [
            "mailboxIds": [drafts: true], "keywords": ["$draft": true, "$seen": true],
            "from": [["name": identity["name"] as? String ?? "", "email": from]], "to": to, "subject": subject,
            "bodyValues": ["b": ["value": text + "\n\nSent from my Apple Watch"]],
            "textBody": [["partId": "b", "type": "text/plain"]],
        ]
        if let mid = e.messageId?.first {
            email["inReplyTo"] = [mid]
            email["references"] = (e.references ?? []) + [mid]
        }
        let s = try await call([
            ["Email/set", ["accountId": acc, "create": ["r": email]], "c"],
            ["EmailSubmission/set", ["accountId": acc, "create": ["s": ["identityId": identityId, "emailId": "#r"]],
                                     "onSuccessUpdateEmail": ["#s": ["mailboxIds/\(drafts)": NSNull(), "mailboxIds/\(sent)": true, "keywords/$draft": NSNull()]]], "x"],
        ], submission: true)
        if let failed = (s["x"]?["notCreated"] as? [String: Any])?.values.first as? [String: Any] {
            throw WatchError.failed(failed["description"] as? String ?? "Couldn't send")
        }
        try? await set(e.id, keyword: "$answered", true)
    }
}

/// Sample mail for the Watch, shown while the iPhone is on sample mail (and for App Review).
enum WatchSample {
    static let account = "sample"
    static func emails(now: Date = Date()) -> [WatchEmail] {
        func at(_ minutes: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(-minutes * 60)) }
        func mail(_ id: String, _ name: String, _ email: String, _ subject: String, _ preview: String, _ ago: Double, seen: Bool = false, star: Bool = false) -> WatchEmail {
            var k: [String: Bool] = [:]
            if seen { k["$seen"] = true }
            if star { k["$flagged"] = true }
            return WatchEmail(id: id, account: account, threadId: id, mailboxIds: nil, keywords: k,
                              from: [WatchAddress(name: name, email: email)], to: nil, cc: nil, replyTo: nil,
                              subject: subject, preview: preview, receivedAt: at(ago), messageId: nil, references: nil)
        }
        return [
            mail("s1", "Maya Chen", "maya@studio-north.example", "Sketches for the spring launch",
                 "Here are the three directions we talked about. I think the second one has the most energy, but see what you think.", 8),
            mail("s2", "Tom Okafor", "tom@example.com", "Saturday plans",
                 "Still on for the climb? I've booked the 10am slot and the café after, if the weather holds.", 35, star: true),
            mail("s3", "Kestrel Bank", "hello@kestrel.example", "Your November statement is ready",
                 "Your statement for November is ready to view in the app. Nothing needs doing right now.", 130, seen: true),
            mail("s4", "Hillside Books", "orders@hillside.example", "Your order is on its way",
                 "Good news: your books left us this morning and should be with you by Friday.", 1440, seen: true),
        ]
    }
}
