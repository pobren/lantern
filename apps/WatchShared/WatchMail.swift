// JMAP Connect on Apple Watch: the accounts the iPhone handed over, and a small JMAP client for the inbox.
// Used by the Watch app and its complication. The tokens sit in the Watch's own Keychain, shared by the two.
// The iPhone app also uses WatchJMAP to send a reply typed on an alert, so this file builds for iOS and macOS too.

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
            list.append(WatchAccount(id: id, label: a["label"] ?? "Mail", session: session))
        }
        for old in all where !list.contains(where: { $0.id == old.id }) {
            delete("token." + old.id)
            delete("grant." + old.id)
        }
        if let replies = context["replies"] as? [String], let data = try? JSONEncoder().encode(replies) { write("replies", data) }
        if let data = try? JSONEncoder().encode(list) { write("list", data) }
        if context["sample"] as? Bool == true { write("sample", Data("1".utf8)) } else { delete("sample") }
    }

    /// The short replies to offer under Reply, as set on the iPhone (Settings, Apple Watch).
    static var replies: [String] {
        guard let data = read("replies"), let list = try? JSONDecoder().decode([String].self, from: data), !list.isEmpty else {
            return QuickReplies.defaults
        }
        return list
    }

    // MARK: The Watch's own Fastmail sign in

    /// A Fastmail sign in made for the Watch alone (from the iPhone's Settings, Apple Watch). With it the Watch
    /// refreshes its own access, so it keeps working away from the iPhone. Without it the Watch uses the short lived
    /// access the iPhone hands over, which runs out after about an hour away from the iPhone.
    static func grant(_ id: String) -> WatchGrant? { read("grant." + id).flatMap { try? JSONDecoder().decode(WatchGrant.self, from: $0) } }
    static func saveGrant(_ id: String, _ g: WatchGrant) { if let data = try? JSONEncoder().encode(g) { write("grant." + id, data) } }
    static func forgetGrant(_ id: String) { delete("grant." + id) }

    /// Takes a sign in the iPhone sent with transferUserInfo, or a request to forget one.
    static func takeGrant(_ info: [String: Any]) {
        if let id = info["forget"] as? String { forgetGrant(id); return }
        guard let g = info["grant"] as? [String: Any], let id = g["id"] as? String, let access = g["access"] as? String,
              let refresh = g["refresh"] as? String, let client = g["client"] as? String,
              let expires = g["expires"] as? Double else { return }
        saveGrant(id, WatchGrant(access: access, refresh: refresh, expires: Date(timeIntervalSince1970: expires), client: client))
    }

    /// Only the Watch app refreshes a sign in. Fastmail's refresh tokens work once, so if the complication refreshed
    /// at the same moment the Watch would be signed out. The complication uses whatever access is current.
    static var canRefresh = false

    /// The Authorization header for an account: the Watch's own sign in when it has one, else what the iPhone sent.
    static func header(_ id: String, force: Bool = false) async throws -> String {
        if let g = grant(id) {
            if !force && g.expires.timeIntervalSinceNow > 90 { return "Bearer " + g.access }
            if canRefresh {
                do { return "Bearer " + (try await WatchRefresher.shared.refresh(id, g).access) }
                catch WatchGrantError.ended { forgetGrant(id) }
                catch { if g.expires.timeIntervalSinceNow > 0 { return "Bearer " + g.access } }
            } else if g.expires.timeIntervalSinceNow > 0 {
                return "Bearer " + g.access
            }
        }
        guard let t = token(id) else { throw WatchError.signIn }
        return JMAPAuth.header(t)
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
        case .signIn: return "Your mail server didn't accept the sign in. Open JMAP Connect on your iPhone, or let the Watch sign in on its own in Settings, Apple Watch."
        case .server(let c): return "Your mail server answered with an error (\(c))."
        case .failed(let why): return why
        }
    }
}

/// Just enough JMAP for the Watch: the inbox, one email's text, flags, archive and a short reply.
final class WatchJMAP: @unchecked Sendable {
    let account: WatchAccount
    /// Gives the Authorization header; true asks for a fresh one after the server refused the last.
    private let auth: @Sendable (Bool) async throws -> String
    private var api: URL?
    private var accountId: String?
    private var boxes: [String: String] = [:]   // role -> mailbox id
    private let http: URLSession

    /// On the Watch: the accounts the iPhone handed over.
    convenience init?(_ account: WatchAccount) {
        guard WatchAccounts.token(account.id) != nil || WatchAccounts.grant(account.id) != nil else { return nil }
        let id = account.id
        self.init(account, auth: { force in try await WatchAccounts.header(id, force: force) })
    }

    init(_ account: WatchAccount, auth: @escaping @Sendable (Bool) async throws -> String) {
        self.account = account
        self.auth = auth
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 25
        c.waitsForConnectivity = false
        http = URLSession(configuration: c)
    }

    private func request(_ url: URL, body: Data? = nil, force: Bool = false) async throws -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(try await auth(force), forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { r.httpMethod = "POST"; r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    private func connect() async throws {
        guard let url = URL(string: account.session) else { throw WatchError.failed("Bad server address") }
        let (data, res) = try await send(url)
        let code = (res as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apiUrl = root["apiUrl"] as? String,
              let acc = (root["primaryAccounts"] as? [String: String])?["urn:ietf:params:jmap:mail"] else { throw WatchError.server(code) }
        api = URL(string: JMAPAuth.resolve(apiUrl, against: res.url ?? url))
        accountId = acc
        let r = try await call([["Mailbox/get", ["accountId": acc, "properties": ["id", "role", "unreadEmails"]], "m"]])
        for m in (r["m"]?["list"] as? [[String: Any]]) ?? [] {
            if let role = m["role"] as? String, let id = m["id"] as? String { boxes[role] = id }
        }
    }

    /// Sends a request; if the server refuses the sign in, asks for fresh access once and tries again.
    private func send(_ url: URL, body: Data? = nil) async throws -> (Data, URLResponse) {
        var (data, res) = try await http.data(for: request(url, body: body))
        if [401, 403].contains((res as? HTTPURLResponse)?.statusCode ?? 0) {
            (data, res) = try await http.data(for: request(url, body: body, force: true))
            if [401, 403].contains((res as? HTTPURLResponse)?.statusCode ?? 0) { throw WatchError.signIn }
        }
        return (data, res)
    }

    private func call(_ calls: [[Any]], submission: Bool = false) async throws -> [String: [String: Any]] {
        if api == nil, accountId == nil { try await connect() }
        guard let api else { throw WatchError.failed("No server") }
        var using = ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"]
        if submission { using.append("urn:ietf:params:jmap:submission") }
        let body = try JSONSerialization.data(withJSONObject: ["using": using, "methodCalls": calls])
        let (data, res) = try await send(api, body: body)
        let code = (res as? HTTPURLResponse)?.statusCode ?? 0
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
        // "account" is ours, not the server's; it goes in before decoding, since WatchEmail's decoder expects it.
        let list = ((r["g"]?["list"] as? [[String: Any]]) ?? []).map { e -> [String: Any] in
            var e = e
            e["account"] = account.id
            return e
        }
        let data = try JSONSerialization.data(withJSONObject: list)
        let emails = try JSONDecoder().decode([WatchEmail].self, from: data)
        let unread = ((r["m"]?["list"] as? [[String: Any]])?.first?["unreadEmails"] as? Int) ?? emails.filter(\.unread).count
        return (emails, unread)
    }

    /// One email with what a reply needs (for a reply typed on an iPhone alert).
    func email(_ id: String) async throws -> WatchEmail {
        let acc = try await ready()
        let r = try await call([["Email/get", ["accountId": acc, "ids": [id], "properties": WatchEmail.properties], "g"]])
        guard var first = (r["g"]?["list"] as? [[String: Any]])?.first else { throw WatchError.failed("That email has gone") }
        first["account"] = account.id
        return try JSONDecoder().decode(WatchEmail.self, from: JSONSerialization.data(withJSONObject: first))
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
        _ = try await call([["Email/set", ["accountId": acc, "update": [id: ["keywords/\(keyword)": on ? (true as Any) : (NSNull() as Any)]]], "s"]])
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
    func reply(to e: WatchEmail, text: String, from device: String = "Apple Watch") async throws {
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
            "bodyValues": ["b": ["value": text + "\n\nSent from my \(device)"]],
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

/// The Watch's own Fastmail sign in.
struct WatchGrant: Codable {
    var access: String
    var refresh: String
    var expires: Date
    var client: String
}

enum WatchGrantError: Error { case ended, failed }

/// Refreshes the Watch's own sign ins one at a time, so two screens asking at once never use a refresh token twice.
actor WatchRefresher {
    static let shared = WatchRefresher()
    private var running: [String: Task<WatchGrant, Error>] = [:]

    func refresh(_ id: String, _ g: WatchGrant) async throws -> WatchGrant {
        if let t = running[id] { return try await t.value }
        let t = Task { try await Self.post(g) }
        running[id] = t
        defer { running[id] = nil }
        let fresh = try await t.value
        WatchAccounts.saveGrant(id, fresh)
        return fresh
    }

    private static func post(_ g: WatchGrant) async throws -> WatchGrant {
        var r = URLRequest(url: URL(string: "https://api.fastmail.com/oauth/refresh")!)
        r.httpMethod = "POST"
        r.timeoutInterval = 25
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let fields = ["client_id": g.client, "grant_type": "refresh_token", "refresh_token": g.refresh,
                      "resource": "https://api.fastmail.com/jmap/session"]
        r.httpBody = Data(fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").utf8)
        let (data, res) = try await URLSession.shared.data(for: r)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (res as? HTTPURLResponse)?.statusCode == 200, let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else {
            if json["error"] as? String == "invalid_grant", json["temporary"] as? Bool != true { throw WatchGrantError.ended }
            throw WatchGrantError.failed
        }
        let life = (json["expires_in"] as? Double) ?? Double(json["expires_in"] as? Int ?? 3600)
        return WatchGrant(access: access, refresh: refresh, expires: Date().addingTimeInterval(life), client: g.client)
    }
}

/// Short replies to send with one tap, from the Watch and from alerts.
enum QuickReplies {
    static let defaults = ["Thanks!", "Will do.", "Sounds good.", "On my way.", "Can I get back to you later?", "Yes", "No"]
}
