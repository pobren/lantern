// The JMAP engine: everything Lantern says to a mail server goes through here (RFC 8620 core, RFC 8621 mail).
// Fastmail runs JMAP on every account, and Mail App will too, so one engine covers both.

import Foundation

enum JMAPError: LocalizedError {
    case badServer
    case signIn
    case http(Int)
    case method(String, String?)
    case missing(String)
    case notFound
    case needServer

    var errorDescription: String? {
        switch self {
        case .badServer: return "That doesn't look like a JMAP server address."
        case .signIn: return "The server didn't accept that sign in. Check the token or app password and try again."
        case .http(let code): return "The server answered with an error (\(code)). Try again in a moment."
        case .method(let type, let detail): return "The server couldn't do that (\(type)\(detail.map { ": \($0)" } ?? ""))."
        case .missing(let what): return "The server left out \(what)."
        case .notFound: return "Couldn't find a JMAP server for that email address. Enter the server's address instead."
        case .needServer: return "Enter your email address or the server's address."
        }
    }
}

/// Where an account lives and how to reach it.
struct ServerKind: Identifiable, Hashable {
    let id: String
    let name: String
    let sessionURL: String
    let tokenHelp: String
    /// Signs in with an email address and app password rather than an API token.
    var usesPassword = false
    /// Self hosted, so the server's address is asked for (or found from the email address).
    var asksServer = false

    /// Fastmail stays the main choice; the other JMAP providers sit underneath it, smaller (Paul, 19 Nov).
    static let otherProviders = true

    static let fastmail = ServerKind(
        id: "fastmail", name: "Fastmail",
        sessionURL: "https://api.fastmail.com/jmap/session",
        tokenHelp: "In Fastmail, open Settings, then Privacy & Security, then Manage API tokens. Make a new token with Email access, Email submission so you can send, and Masked Email and Contacts if you use them.")
    static let mailApp = ServerKind(
        id: "mailapp", name: "Mail App",
        sessionURL: "",
        tokenHelp: "In Mail App, open Admin, then API & webhooks, and make a new key with Read, Organise, Send and Delete for your mailboxes. Use your email address, the key as the password and your Mail App address as the server.",
        usesPassword: true, asksServer: true)
    static let stalwart = ServerKind(
        id: "stalwart", name: "Stalwart",
        sessionURL: "",
        tokenHelp: "In Stalwart's web interface, open your account's security settings and make an app password for JMAP Connect. The server is the address you open Stalwart's web interface on.",
        usesPassword: true, asksServer: true)
    static let thundermail = ServerKind(
        id: "thundermail", name: "Thundermail",
        sessionURL: "https://mail.thundermail.com/.well-known/jmap",
        tokenHelp: "In your Thundermail dashboard, open Email Settings and press Create app password. Use your Thundermail address and that app password.",
        usesPassword: true)
    static let mailbux = ServerKind(
        id: "mailbux", name: "Mailbux",
        sessionURL: "https://my.mailbux.com/jmap/session",
        tokenHelp: "Use your Mailbux email address and password, or an app password if you've made one.",
        usesPassword: true)
    static let cyrus = ServerKind(
        id: "cyrus", name: "Cyrus",
        sessionURL: "",
        tokenHelp: "Use the email address and password (or app password) from whoever runs your Cyrus server, and its address.",
        usesPassword: true, asksServer: true)
    static let other = ServerKind(
        id: "other", name: "Another JMAP server",
        sessionURL: "",
        tokenHelp: "Use your email address and an app password. Leave the server empty to find it from your email address, or enter the address your provider gives for JMAP. If your provider gives you an API token instead, leave the email address empty.",
        usesPassword: true, asksServer: true)

    /// The smaller choices under Fastmail, in the order the website lists them.
    static let providers: [ServerKind] = [stalwart, thundermail, mailbux, cyrus, mailApp, other]
    static let all: [ServerKind] = [fastmail] + providers
    static func named(_ id: String) -> ServerKind? { all.first { $0.id == id } }
}

/// Follows a redirect from /.well-known/jmap with the sign in still attached, but only over https and only to the
/// same server or another server under the same domain (mail.example.com to jmap.example.com), never elsewhere.
final class KeepSignIn: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let base: String
    private let header: String

    init(from url: URL, header: String) {
        let labels = (url.host ?? "").lowercased().split(separator: ".")
        // Two labels (example.com), or three for country domains such as example.co.uk.
        let short = labels.count >= 3 && labels.last?.count == 2 && (labels.dropLast().last?.count ?? 0) <= 3
        base = labels.suffix(short ? 3 : 2).joined(separator: ".")
        self.header = header
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        let host = (request.url?.host ?? "").lowercased()
        if request.url?.scheme == "https", !base.isEmpty, host == base || host.hasSuffix("." + base) {
            next.setValue(header, forHTTPHeaderField: "Authorization")
        } else {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }
}

struct JMAPSession: Decodable {
    var apiUrl: String
    var downloadUrl: String
    var uploadUrl: String
    var eventSourceUrl: String?
    let username: String
    let primaryAccounts: [String: String]
    let state: String
}

final class JMAPClient: @unchecked Sendable {
    static let core = "urn:ietf:params:jmap:core"
    static let mail = "urn:ietf:params:jmap:mail"
    static let submission = "urn:ietf:params:jmap:submission"

    let sessionURL: URL
    private let token: String
    private(set) var session: JMAPSession?
    /// Where the session really lives once any /.well-known/jmap redirect is followed; saved so later starts skip it.
    private(set) var finalSessionURL: URL?
    /// What the server says it can do (the session's capabilities), and what the mail account can do.
    private(set) var capabilities: [String: Any] = [:]
    private(set) var accountCapabilities: [String: Any] = [:]
    private let http: URLSession

    init(sessionURL: URL, token: String) {
        self.sessionURL = sessionURL
        self.token = token
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        // Sample mail is answered inside the app and never goes near the network.
        if sessionURL.host == Demo.host { config.protocolClasses = [DemoProtocol.self] }
        http = URLSession(configuration: config)
    }

    var accountId: String? { session?.primaryAccounts[Self.mail] }

    private func request(_ url: URL, method: String = "GET", body: Data? = nil, contentType: String = "application/json") -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(JMAPAuth.header(token), forHTTPHeaderField: "Authorization")
        if let body {
            r.httpBody = body
            r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    @discardableResult
    func connect() async throws -> JMAPSession {
        // /.well-known/jmap usually redirects to the real session address; keep signing in across that hop.
        let (data, response) = try await http.data(for: request(sessionURL), delegate: KeepSignIn(from: sessionURL, header: JMAPAuth.header(token)))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw JMAPError.signIn }
        guard code == 200 else { throw JMAPError.http(code) }
        guard var s = try? JSONDecoder().decode(JMAPSession.self, from: data) else { throw JMAPError.badServer }
        // Stalwart gives addresses relative to the session (apiUrl "/jmap/"); Fastmail gives full ones.
        let base = response.url ?? sessionURL
        finalSessionURL = base
        s.apiUrl = JMAPAuth.resolve(s.apiUrl, against: base)
        s.downloadUrl = JMAPAuth.resolve(s.downloadUrl, against: base)
        s.uploadUrl = JMAPAuth.resolve(s.uploadUrl, against: base)
        s.eventSourceUrl = s.eventSourceUrl.map { JMAPAuth.resolve($0, against: base) }
        guard let mailAccount = s.primaryAccounts[Self.mail] else { throw JMAPError.missing("a mail account") }
        if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            capabilities = raw["capabilities"] as? [String: Any] ?? [:]
            accountCapabilities = ((raw["accounts"] as? [String: Any])?[mailAccount] as? [String: Any])?["accountCapabilities"] as? [String: Any] ?? [:]
        }
        session = s
        return s
    }

    /// One round trip with any number of method calls. Returns each call's arguments by its call id.
    func call(_ calls: [[Any]], using: [String] = [JMAPClient.core, JMAPClient.mail]) async throws -> [String: [String: Any]] {
        if session == nil { try await connect() }
        guard let s = session, let url = URL(string: s.apiUrl) else { throw JMAPError.badServer }
        let body = try JSONSerialization.data(withJSONObject: ["using": using, "methodCalls": calls])
        let (data, response) = try await http.data(for: request(url, method: "POST", body: body))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw JMAPError.signIn }
        guard code == 200 else { throw JMAPError.http(code) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responses = root["methodResponses"] as? [[Any]] else { throw JMAPError.missing("an answer") }
        var out: [String: [String: Any]] = [:]
        for r in responses where r.count == 3 {
            guard let name = r[0] as? String, let args = r[1] as? [String: Any], let id = r[2] as? String else { continue }
            if name == "error" {
                let method = calls.first { ($0.count == 3 ? $0[2] as? String : nil) == id }?.first as? String ?? id
                let detail = [method, args["description"] as? String, (args["properties"] as? [String])?.joined(separator: ", ")]
                    .compactMap { $0 }.joined(separator: ", ")
                throw JMAPError.method(args["type"] as? String ?? "error", detail)
            }
            out[id] = args
        }
        return out
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: Any?) throws -> T {
        guard let value else { throw JMAPError.missing("data") }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Mail

    func mailboxes() async throws -> [Mailbox] {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        let r = try await call([["Mailbox/get", ["accountId": acc], "m"]])
        return try Self.decode([Mailbox].self, from: r["m"]?["list"])
    }

    /// Makes a new folder, inside another one if `parentId` is set.
    func createMailbox(name: String, parentId: String?) async throws {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        let box: [String: Any] = ["name": name, "parentId": parentId.map { $0 as Any } ?? NSNull()]
        let r = try await call([["Mailbox/set", ["accountId": acc, "create": ["new": box]], "m"]])
        if let failed = r["m"]?["notCreated"] as? [String: Any], let first = failed.values.first as? [String: Any] {
            throw JMAPError.method(first["type"] as? String ?? "notCreated", first["description"] as? String)
        }
    }

    func renameMailbox(id: String, name: String) async throws {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        let r = try await call([["Mailbox/set", ["accountId": acc, "update": [id: ["name": name]]], "m"]])
        if let failed = r["m"]?["notUpdated"] as? [String: Any], let first = failed.values.first as? [String: Any] {
            throw JMAPError.method(first["type"] as? String ?? "notUpdated", first["description"] as? String)
        }
    }

    /// One email by its id, with what the lists need.
    func email(_ id: String) async throws -> Email? {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        let r = try await call([["Email/get", ["accountId": acc, "ids": [id], "properties": Email.listProperties], "g"]])
        return try Self.decode([Email].self, from: r["g"]?["list"]).first
    }

    func identities() async throws -> [Identity] {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        let r = try await call([["Identity/get", ["accountId": acc], "i"]], using: [Self.core, Self.mail, Self.submission])
        let list = try Self.decode([Identity].self, from: r["i"]?["list"])
        // Some servers (Cyrus, as some hosts set it up) leave the address empty; the sign in name is the address then.
        guard let me = session?.username, me.contains("@") else { return list }
        return list.map { i in
            guard i.email.isEmpty else { return i }
            return Identity(id: i.id, name: i.name, email: me, textSignature: i.textSignature, replyTo: i.replyTo)
        }
    }

    /// The newest emails matching a filter, with what the lists need (no bodies). `position` pages further down.
    func emails(filter: [String: Any], limit: Int = 100, position: Int = 0, collapseThreads: Bool = true) async throws -> [Email] {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        var query: [String: Any] = ["accountId": acc, "filter": filter,
                                    "sort": [["property": "receivedAt", "isAscending": false]],
                                    "limit": limit, "position": position, "collapseThreads": collapseThreads]
        if filter.isEmpty { query.removeValue(forKey: "filter") }
        let r = try await call([
            ["Email/query", query, "q"],
            ["Email/get", ["accountId": acc, "#ids": ["resultOf": "q", "name": "Email/query", "path": "/ids"],
                           "properties": Email.listProperties], "g"]
        ])
        return try Self.decode([Email].self, from: r["g"]?["list"])
    }

    // MARK: Keeping a copy on the device

    /// The server's current state string for emails, to ask later what changed since.
    func emailState() async throws -> String {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        let r = try await call([["Email/get", ["accountId": acc, "ids": [String](), "properties": ["id"]], "g"]])
        guard let state = r["g"]?["state"] as? String else { throw JMAPError.missing("a state") }
        return state
    }

    /// One page of every email in the account, newest first, after the email `anchor` (the last of the page before).
    func allEmails(after anchor: String?, limit: Int) async throws -> [Email] {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        var query: [String: Any] = ["accountId": acc, "sort": [["property": "receivedAt", "isAscending": false]],
                                    "limit": limit, "collapseThreads": false]
        if let anchor { query["anchor"] = anchor; query["anchorOffset"] = 1 } else { query["position"] = 0 }
        let r = try await call([
            ["Email/query", query, "q"],
            ["Email/get", ["accountId": acc, "#ids": ["resultOf": "q", "name": "Email/query", "path": "/ids"],
                           "properties": Email.listProperties], "g"]
        ])
        return try Self.decode([Email].self, from: r["g"]?["list"])
    }

    /// What changed since a state: emails added or changed, and ids removed. Throws `JMAPError.method` with
    /// "cannotCalculateChanges" when the server has forgotten that state and everything must be fetched again.
    func emailChanges(since state: String) async throws -> (changed: [String], removed: [String], state: String, more: Bool) {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        let r = try await call([["Email/changes", ["accountId": acc, "sinceState": state, "maxChanges": 500], "c"]])
        guard let c = r["c"], let newState = c["newState"] as? String else { throw JMAPError.missing("changes") }
        let changed = ((c["created"] as? [String]) ?? []) + ((c["updated"] as? [String]) ?? [])
        return (changed, (c["destroyed"] as? [String]) ?? [], newState, (c["hasMoreChanges"] as? Bool) ?? false)
    }

    /// Emails by id, with what the lists need. Ids the server no longer has are left out.
    func emails(ids: [String]) async throws -> [Email] {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        guard !ids.isEmpty else { return [] }
        let r = try await call([["Email/get", ["accountId": acc, "ids": ids, "properties": Email.listProperties], "g"]])
        return try Self.decode([Email].self, from: r["g"]?["list"])
    }

    /// The readable text of several emails at once, for reading and searching offline. Pictures sent inside an
    /// email aren't fetched here; opening the email fills them in.
    func contents(of ids: [String]) async throws -> [String: SavedPage] {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        guard !ids.isEmpty else { return [:] }
        let r = try await call([["Email/get", ["accountId": acc, "ids": ids,
                                               "properties": ["id", "htmlBody", "textBody", "bodyValues", "attachments"],
                                               "bodyProperties": ["partId", "blobId", "type", "cid", "name", "size"],
                                               "fetchHTMLBodyValues": true, "fetchTextBodyValues": true,
                                               "maxBodyValueBytes": 1_000_000], "p"]])
        var out: [String: SavedPage] = [:]
        for item in (r["p"]?["list"] as? [[String: Any]]) ?? [] {
            guard let id = item["id"] as? String else { continue }
            let values = (item["bodyValues"] as? [String: [String: Any]]) ?? [:]
            let htmlParts = (item["htmlBody"] as? [[String: Any]]) ?? []
            let textParts = (item["textBody"] as? [[String: Any]]) ?? []
            var html = ""
            for part in htmlParts.isEmpty ? textParts : htmlParts {
                guard let pid = part["partId"] as? String, let value = values[pid]?["value"] as? String else { continue }
                if (part["type"] as? String)?.lowercased() == "text/html" { html += value }
                else { html += "<div class=\"lantern-text\">" + Self.escape(value) + "</div>" }
            }
            let text = textParts.compactMap { $0["partId"] as? String }.compactMap { values[$0]?["value"] as? String }
                .joined(separator: "\n\n").replacingOccurrences(of: "\r\n", with: "\n")
            let files: [Attachment] = ((item["attachments"] as? [[String: Any]]) ?? []).compactMap { f in
                guard let blobId = f["blobId"] as? String else { return nil }
                // Pictures shown inside the email aren't listed as files to open.
                if f["cid"] is String, let t = f["type"] as? String, t.lowercased().hasPrefix("image/"),
                   html.range(of: "cid:", options: .caseInsensitive) != nil { return nil }
                return Attachment(blobId: blobId, name: (f["name"] as? String) ?? "Attachment",
                                  type: (f["type"] as? String) ?? "application/octet-stream", size: (f["size"] as? Int) ?? 0)
            }
            out[id] = SavedPage(html: html, text: text.isEmpty ? Self.plain(html) : text, attachments: files, complete: false)
        }
        return out
    }

    /// Rough plain text from HTML, for the search index when an email has no plain text part.
    static func plain(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<(style|script)[^>]*>[\\s\\S]*?</\\1>", with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (a, b) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// Every email in a conversation, oldest first.
    func thread(_ threadId: String) async throws -> [Email] {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        let r = try await call([
            ["Thread/get", ["accountId": acc, "ids": [threadId]], "t"],
            ["Email/get", ["accountId": acc, "#ids": ["resultOf": "t", "name": "Thread/get", "path": "/list/*/emailIds"],
                           "properties": Email.listProperties], "g"]
        ])
        let list = try Self.decode([Email].self, from: r["g"]?["list"])
        return list.sorted { $0.date < $1.date }
    }

    /// The plain text of one email, for quoting in replies and forwards.
    func body(of id: String) async throws -> String {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        let r = try await call([["Email/get", ["accountId": acc, "ids": [id],
                                               "properties": ["textBody", "bodyValues"],
                                               "fetchTextBodyValues": true, "maxBodyValueBytes": 256_000], "b"]])
        guard let list = r["b"]?["list"] as? [[String: Any]], let first = list.first else { return "" }
        let parts = (first["textBody"] as? [[String: Any]]) ?? []
        let values = (first["bodyValues"] as? [String: [String: Any]]) ?? [:]
        let text = parts.compactMap { $0["partId"] as? String }.compactMap { values[$0]?["value"] as? String }.joined(separator: "\n\n")
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// The email as a reader sees it: its HTML (or its plain text turned into HTML), with pictures sent inside the
    /// email (cid: links) swapped for data: addresses so they show without any further fetching.
    func page(of id: String) async throws -> (html: String, attachments: [Attachment]) {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        let r = try await call([["Email/get", ["accountId": acc, "ids": [id],
                                               "properties": ["htmlBody", "textBody", "bodyValues", "attachments"],
                                               "bodyProperties": ["partId", "blobId", "type", "cid", "name", "size"],
                                               "fetchHTMLBodyValues": true, "maxBodyValueBytes": 2_000_000], "p"]])
        guard let first = (r["p"]?["list"] as? [[String: Any]])?.first else { return ("", []) }
        let values = (first["bodyValues"] as? [String: [String: Any]]) ?? [:]
        let parts = (first["htmlBody"] as? [[String: Any]]) ?? (first["textBody"] as? [[String: Any]]) ?? []
        var html = ""
        for part in parts {
            guard let pid = part["partId"] as? String, let value = values[pid]?["value"] as? String else { continue }
            if (part["type"] as? String)?.lowercased() == "text/html" { html += value }
            else { html += "<div class=\"lantern-text\">" + Self.escape(value) + "</div>" }
        }
        // Pictures inside the email, linked by cid:, become data: addresses.
        let files = (first["attachments"] as? [[String: Any]]) ?? []
        var used = Set<String>()
        for part in files + parts {
            guard var cid = part["cid"] as? String, let blobId = part["blobId"] as? String,
                  let type = part["type"] as? String, type.lowercased().hasPrefix("image/"),
                  (part["size"] as? Int ?? 0) < 5_000_000 else { continue }
            cid = cid.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            // Senders write cid: links in any case, and some percent-encode them.
            let links = Set(["cid:\(cid)", "cid:" + (cid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cid)])
            guard links.contains(where: { html.range(of: $0, options: .caseInsensitive) != nil }),
                  let data = try? await download(blobId: blobId, type: type) else { continue }
            let inline = "data:\(type);base64,\(data.base64EncodedString())"
            for link in links { html = html.replacingOccurrences(of: link, with: inline, options: .caseInsensitive) }
            used.insert(blobId)
        }
        // Files to open or save: everything attached, except pictures already shown inside the email.
        let attachments: [Attachment] = files.compactMap { f in
            guard let blobId = f["blobId"] as? String, !used.contains(blobId) else { return nil }
            let type = (f["type"] as? String) ?? "application/octet-stream"
            return Attachment(blobId: blobId, name: (f["name"] as? String) ?? "Attachment", type: type, size: (f["size"] as? Int) ?? 0)
        }
        return (html, attachments)
    }

    /// Fetches a file the server holds (an attachment or a picture) with the account's token.
    func download(blobId: String, type: String) async throws -> Data {
        guard let s = session, let acc = accountId else { throw JMAPError.missing("an account") }
        let enc: (String) -> String = { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? $0 }
        let address = s.downloadUrl
            .replacingOccurrences(of: "{accountId}", with: enc(acc))
            .replacingOccurrences(of: "{blobId}", with: enc(blobId))
            .replacingOccurrences(of: "{type}", with: enc(type))
            .replacingOccurrences(of: "{name}", with: "file")
        guard let url = URL(string: address) else { throw JMAPError.badServer }
        let (data, response) = try await http.data(for: request(url))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw JMAPError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
        return data
    }

    /// Sends a file to the server and returns its blob id, for attaching to an email.
    func upload(_ data: Data, type: String) async throws -> String {
        if session == nil { try await connect() }
        guard let s = session, let acc = accountId else { throw JMAPError.missing("an account") }
        let enc = acc.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? acc
        guard let url = URL(string: s.uploadUrl.replacingOccurrences(of: "{accountId}", with: enc)) else { throw JMAPError.badServer }
        var r = request(url, method: "POST", body: data, contentType: type)
        r.timeoutInterval = 300
        let (out, response) = try await http.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 201 else { throw JMAPError.http(code) }
        guard let root = try JSONSerialization.jsonObject(with: out) as? [String: Any], let blobId = root["blobId"] as? String else {
            throw JMAPError.missing("the uploaded file")
        }
        return blobId
    }

    /// Saves the plain text signature for one of your addresses on the server, so every app shows the same one.
    func setSignature(identityId: String, text: String) async throws {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        let r = try await call([["Identity/set", ["accountId": acc, "update": [identityId: ["textSignature": text]]], "s"]],
                               using: [Self.core, Self.mail, Self.submission])
        if let failed = r["s"]?["notUpdated"] as? [String: Any], let first = failed.values.first as? [String: Any] {
            throw JMAPError.method(first["type"] as? String ?? "notUpdated", first["description"] as? String)
        }
    }

    /// Saves where replies to one of your addresses should go (empty for the address itself).
    func setReplyTo(identityId: String, to addresses: [EmailAddress]) async throws {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        let value: Any = addresses.isEmpty ? NSNull() : addresses.map { ["name": $0.name.map { $0 as Any } ?? NSNull(), "email": $0.email] as [String: Any] }
        let r = try await call([["Identity/set", ["accountId": acc, "update": [identityId: ["replyTo": value]]], "s"]],
                               using: [Self.core, Self.mail, Self.submission])
        if let failed = r["s"]?["notUpdated"] as? [String: Any], let first = failed.values.first as? [String: Any] {
            throw JMAPError.method(first["type"] as? String ?? "notUpdated", first["description"] as? String)
        }
    }

    /// Adds an address you can send from. The server only allows addresses that belong to the account.
    func createIdentity(name: String, email: String) async throws {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        let r = try await call([["Identity/set", ["accountId": acc, "create": ["new": ["name": name, "email": email]]], "s"]],
                               using: [Self.core, Self.mail, Self.submission])
        if let failed = r["s"]?["notCreated"] as? [String: Any], let first = failed.values.first as? [String: Any] {
            throw JMAPError.method(first["type"] as? String ?? "notCreated", first["description"] as? String)
        }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Changes keywords or mailboxes on several emails at once, as JMAP patches ("keywords/$seen": true).
    func update(_ patches: [String: [String: Any]]) async throws {
        guard let acc = accountId, !patches.isEmpty else { return }
        let r = try await call([["Email/set", ["accountId": acc, "update": patches], "u"]])
        if let failed = r["u"]?["notUpdated"] as? [String: Any], let first = failed.values.first as? [String: Any] {
            throw JMAPError.method(first["type"] as? String ?? "notUpdated", first["description"] as? String)
        }
    }

    /// The email as JMAP wants it, ready to save in Drafts (and, when sending, to submit).
    private func message(from identity: Identity, as address: String?, to: [EmailAddress], cc: [EmailAddress], bcc: [EmailAddress], subject: String, text: String,
                         inReplyTo: String?, references: [String], attachments: [Outgoing], drafts: String) -> [String: Any] {
        // Apple Mail shows attachments straight after the last line of text, so end on a blank line
        // to give them a line of their own.
        var body = text
        if !attachments.isEmpty {
            while body.hasSuffix(" ") { body.removeLast() }
            if !body.hasSuffix("\n\n") { body += body.hasSuffix("\n") ? "\n" : "\n\n" }
        }
        var draft: [String: Any] = [
            "mailboxIds": [drafts: true],
            "keywords": ["$draft": true, "$seen": true],
            "from": [["name": identity.name, "email": address ?? identity.email]],
            "to": to.map { ["name": $0.name ?? "", "email": $0.email] },
            "subject": subject,
            "bodyValues": ["body": ["value": body]],
            "textBody": [["partId": "body", "type": "text/plain"]]
        ]
        if !attachments.isEmpty {
            draft["attachments"] = attachments.map { ["blobId": $0.blobId, "type": $0.type, "name": $0.name, "disposition": "attachment"] }
        }
        if let replyTo = identity.replyTo, !replyTo.isEmpty {
            draft["replyTo"] = replyTo.map { ["name": $0.name ?? "", "email": $0.email] }
        }
        if !cc.isEmpty { draft["cc"] = cc.map { ["name": $0.name ?? "", "email": $0.email] } }
        // Bcc stays on your copy in Sent; the server sends to those addresses but leaves the header out of what others get.
        if !bcc.isEmpty { draft["bcc"] = bcc.map { ["name": $0.name ?? "", "email": $0.email] } }
        if let inReplyTo { draft["inReplyTo"] = [inReplyTo]; draft["references"] = references + [inReplyTo] }
        return draft
    }

    /// Saves an unfinished email in Drafts, replacing the earlier copy when it's a draft being picked up again.
    /// Returns the new draft's id.
    @discardableResult
    func saveDraft(from identity: Identity, as address: String? = nil, to: [EmailAddress], cc: [EmailAddress], bcc: [EmailAddress], subject: String, text: String,
                   inReplyTo: String?, references: [String] = [], attachments: [Outgoing] = [], drafts: String, replacing: String? = nil) async throws -> String {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        var args: [String: Any] = ["accountId": acc,
                                   "create": ["draft": message(from: identity, as: address, to: to, cc: cc, bcc: bcc, subject: subject, text: text,
                                                               inReplyTo: inReplyTo, references: references, attachments: attachments, drafts: drafts)]]
        if let replacing { args["destroy"] = [replacing] }
        let r = try await call([["Email/set", args, "c"]])
        if let failed = r["c"]?["notCreated"] as? [String: Any], let first = failed.values.first as? [String: Any] {
            throw JMAPError.method(first["type"] as? String ?? "notCreated", first["description"] as? String)
        }
        let created = r["c"]?["created"] as? [String: Any]
        return ((created?["draft"] as? [String: Any])?["id"] as? String) ?? ""
    }

    /// Sends a plain text email: saves it as a draft, submits it, then files it in Sent. When the email started
    /// life as a saved draft, that copy is removed.
    func send(from identity: Identity, as address: String? = nil, to: [EmailAddress], cc: [EmailAddress], bcc: [EmailAddress] = [], subject: String, text: String,
              inReplyTo: String?, references: [String] = [], attachments: [Outgoing] = [],
              drafts: String, sent: String, scheduled: String? = nil, replacing: String? = nil, sendAt: Date? = nil) async throws {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        var submission: [String: Any] = ["identityId": identity.id, "emailId": "#draft"]
        // Sent mail is filed in Sent. Mail held to send later waits in Scheduled (when the account has one, as
        // Fastmail does), and moves on to Sent once it has gone (releaseScheduled).
        var filed = sent
        if let sendAt, sendAt > Date().addingTimeInterval(30) {
            if let scheduled { filed = scheduled }
            // Send later (RFC 4865 FUTURERELEASE through JMAP): the server holds the email until then.
            let from = address ?? identity.email
            let all = (to + cc + bcc).map { ["email": $0.email] }
            submission["envelope"] = ["mailFrom": ["email": from, "parameters": ["HOLDUNTIL": Self.utc(sendAt)]], "rcptTo": all]
        }
        let draft = message(from: identity, as: address, to: to, cc: cc, bcc: bcc, subject: subject, text: text,
                            inReplyTo: inReplyTo, references: references, attachments: attachments, drafts: drafts)
        var create: [String: Any] = ["accountId": acc, "create": ["draft": draft]]
        if let replacing { create["destroy"] = [replacing] }
        let r = try await call([
            ["Email/set", create, "c"],
            ["EmailSubmission/set", ["accountId": acc,
                                      "create": ["send": submission],
                                      "onSuccessUpdateEmail": ["#send": ["mailboxIds/\(drafts)": NSNull(), "mailboxIds/\(filed)": true,
                                                                         "keywords/$draft": NSNull()]]], "s"]
        ], using: [Self.core, Self.mail, Self.submission])
        if let failed = r["c"]?["notCreated"] as? [String: Any], let first = failed.values.first as? [String: Any] {
            throw JMAPError.method(first["type"] as? String ?? "notCreated", first["description"] as? String)
        }
        if let failed = r["s"]?["notCreated"] as? [String: Any], let first = failed.values.first as? [String: Any] {
            throw JMAPError.method(first["type"] as? String ?? "notSent", first["description"] as? String)
        }
    }

    /// Opens the server's push channel. Each time mail changes, `changed` runs; the stream ends when the task is cancelled.
    func listen(changed: @escaping @Sendable () async -> Void) async {
        guard let template = session?.eventSourceUrl else { return }
        let address = template.replacingOccurrences(of: "{types}", with: "Email,Mailbox")
            .replacingOccurrences(of: "{closeafter}", with: "no")
            .replacingOccurrences(of: "{ping}", with: "60")
        guard let url = URL(string: address) else { return }
        var r = request(url)
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 600
        while !Task.isCancelled {
            do {
                let (bytes, _) = try await http.bytes(for: r)
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    if line.hasPrefix("event: state") {
                        await changed()
                    }
                }
            } catch {
                // Dropped connections are normal (sleep, Wi-Fi changes): wait a little and listen again.
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }
}

/// Trims quoted replies so a conversation shows only what each person actually wrote.
enum Quote {
    static func newText(_ text: String) -> String {
        var kept: [String] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(">") { continue }
            // "On Tue, 17 Nov 2026 at 09:42, Maya Chen <maya@...> wrote:" starts the quoted part.
            if t.hasPrefix("On ") && (t.hasSuffix("wrote:") || (i + 1 < lines.count && lines[i + 1].trimmingCharacters(in: .whitespaces).hasSuffix("wrote:"))) { break }
            if t == "-----Original Message-----" || t.hasPrefix("________________________________") { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
