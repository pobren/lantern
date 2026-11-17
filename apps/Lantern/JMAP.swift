// The JMAP engine: everything Lantern says to a mail server goes through here (RFC 8620 core, RFC 8621 mail).
// Fastmail runs JMAP on every account, and Mail App will too, so one engine covers both.

import Foundation

enum JMAPError: LocalizedError {
    case badServer
    case signIn
    case http(Int)
    case method(String, String?)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .badServer: return "That doesn't look like a JMAP server address."
        case .signIn: return "The server didn't accept that token. Check it and try again."
        case .http(let code): return "The server answered with an error (\(code)). Try again in a moment."
        case .method(let type, let detail): return "The server couldn't do that (\(type)\(detail.map { ": \($0)" } ?? ""))."
        case .missing(let what): return "The server left out \(what)."
        }
    }
}

/// Where an account lives and how to reach it.
struct ServerKind: Identifiable, Hashable {
    let id: String
    let name: String
    let sessionURL: String
    let tokenHelp: String

    static let fastmail = ServerKind(
        id: "fastmail", name: "Fastmail",
        sessionURL: "https://api.fastmail.com/jmap/session",
        tokenHelp: "In Fastmail, open Settings, then Privacy & Security, then Manage API tokens. Make a new token with Email access, and Email submission so you can send.")
    static let mailApp = ServerKind(
        id: "mailapp", name: "Mail App",
        sessionURL: "",
        tokenHelp: "In Mail App, open Settings, then App passwords, and make one for this Mac. Use your Mail App address as the server.")
    static let other = ServerKind(
        id: "other", name: "Another JMAP server",
        sessionURL: "",
        tokenHelp: "Use the server's JMAP session address (it often ends /.well-known/jmap) and an API token from your provider.")
}

struct JMAPSession: Decodable {
    let apiUrl: String
    let downloadUrl: String
    let uploadUrl: String
    let eventSourceUrl: String?
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
    private let http: URLSession

    init(sessionURL: URL, token: String) {
        self.sessionURL = sessionURL
        self.token = token
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        http = URLSession(configuration: config)
    }

    var accountId: String? { session?.primaryAccounts[Self.mail] }

    private func request(_ url: URL, method: String = "GET", body: Data? = nil, contentType: String = "application/json") -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.httpBody = body
            r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    @discardableResult
    func connect() async throws -> JMAPSession {
        let (data, response) = try await http.data(for: request(sessionURL))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw JMAPError.signIn }
        guard code == 200 else { throw JMAPError.http(code) }
        guard let s = try? JSONDecoder().decode(JMAPSession.self, from: data) else { throw JMAPError.badServer }
        guard s.primaryAccounts[Self.mail] != nil else { throw JMAPError.missing("a mail account") }
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

    func identities() async throws -> [Identity] {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        let r = try await call([["Identity/get", ["accountId": acc], "i"]], using: [Self.core, Self.mail, Self.submission])
        return try Self.decode([Identity].self, from: r["i"]?["list"])
    }

    /// Header properties are optional extras: if a server turns them down, Lantern carries on without them.
    private var headersRefused = false

    /// The newest emails matching a filter, with what the lists need (no bodies).
    func emails(filter: [String: Any], limit: Int = 80, collapseThreads: Bool = false) async throws -> [Email] {
        do {
            return try await fetchEmails(filter: filter, limit: limit, collapseThreads: collapseThreads, headers: !headersRefused)
        } catch JMAPError.method(let type, _) where type == "invalidArguments" && !headersRefused {
            headersRefused = true
            return try await fetchEmails(filter: filter, limit: limit, collapseThreads: collapseThreads, headers: false)
        }
    }

    private func fetchEmails(filter: [String: Any], limit: Int, collapseThreads: Bool, headers: Bool) async throws -> [Email] {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        var query: [String: Any] = ["accountId": acc, "filter": filter,
                                    "sort": [["property": "receivedAt", "isAscending": false]], "limit": limit]
        if collapseThreads { query["collapseThreads"] = true }
        let properties = headers ? Email.listProperties : Email.listProperties.filter { !$0.hasPrefix("header:") }
        let r = try await call([
            ["Email/query", query, "q"],
            ["Email/get", ["accountId": acc, "#ids": ["resultOf": "q", "name": "Email/query", "path": "/ids"],
                           "properties": properties], "g"]
        ])
        return try Self.decode([Email].self, from: r["g"]?["list"])
    }

    /// The plain text of one email, for reading.
    func body(of id: String) async throws -> String {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        let r = try await call([["Email/get", ["accountId": acc, "ids": [id],
                                               "properties": ["textBody", "bodyValues"],
                                               "fetchTextBodyValues": true, "maxBodyValueBytes": 256_000], "b"]])
        guard let list = r["b"]?["list"] as? [[String: Any]], let first = list.first else { return "" }
        let parts = (first["textBody"] as? [[String: Any]]) ?? []
        let values = (first["bodyValues"] as? [String: [String: Any]]) ?? [:]
        let text = parts.compactMap { $0["partId"] as? String }.compactMap { values[$0]?["value"] as? String }.joined(separator: "\n\n")
        return Quote.newText(text)
    }

    /// The email as a reader sees it: its HTML (or its plain text turned into HTML), with pictures sent inside the
    /// email (cid: links) swapped for data: addresses so they show without any further fetching.
    func page(of id: String) async throws -> String {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        let r = try await call([["Email/get", ["accountId": acc, "ids": [id],
                                               "properties": ["htmlBody", "textBody", "bodyValues", "attachments"],
                                               "bodyProperties": ["partId", "blobId", "type", "cid", "name", "size"],
                                               "fetchHTMLBodyValues": true, "maxBodyValueBytes": 2_000_000], "p"]])
        guard let first = (r["p"]?["list"] as? [[String: Any]])?.first else { return "" }
        let values = (first["bodyValues"] as? [String: [String: Any]]) ?? [:]
        let parts = (first["htmlBody"] as? [[String: Any]]) ?? (first["textBody"] as? [[String: Any]]) ?? []
        var html = ""
        for part in parts {
            guard let pid = part["partId"] as? String, let value = values[pid]?["value"] as? String else { continue }
            if (part["type"] as? String)?.lowercased() == "text/html" { html += value }
            else { html += "<div class=\"lantern-text\">" + Self.escape(value) + "</div>" }
        }
        // Pictures inside the email, linked by cid:, become data: addresses.
        let inline = ((first["attachments"] as? [[String: Any]]) ?? []) + parts
        for part in inline {
            guard var cid = part["cid"] as? String, let blobId = part["blobId"] as? String,
                  let type = part["type"] as? String, type.lowercased().hasPrefix("image/"),
                  (part["size"] as? Int ?? 0) < 5_000_000 else { continue }
            cid = cid.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            guard html.contains("cid:\(cid)"), let data = try? await download(blobId: blobId, type: type) else { continue }
            html = html.replacingOccurrences(of: "cid:\(cid)", with: "data:\(type);base64,\(data.base64EncodedString())")
        }
        return html
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

    /// Sends a plain text email: saves it as a draft, submits it, then files it in Sent.
    func send(from identity: Identity, to: [EmailAddress], cc: [EmailAddress], subject: String, text: String,
              inReplyTo: String?, drafts: String, sent: String) async throws {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        var draft: [String: Any] = [
            "mailboxIds": [drafts: true],
            "keywords": ["$draft": true, "$seen": true],
            "from": [["name": identity.name, "email": identity.email]],
            "to": to.map { ["name": $0.name ?? "", "email": $0.email] },
            "subject": subject,
            "bodyValues": ["body": ["value": text]],
            "textBody": [["partId": "body", "type": "text/plain"]]
        ]
        if !cc.isEmpty { draft["cc"] = cc.map { ["name": $0.name ?? "", "email": $0.email] } }
        if let inReplyTo { draft["inReplyTo"] = [inReplyTo]; draft["references"] = [inReplyTo] }
        let r = try await call([
            ["Email/set", ["accountId": acc, "create": ["draft": draft]], "c"],
            ["EmailSubmission/set", ["accountId": acc,
                                      "create": ["send": ["identityId": identity.id, "emailId": "#draft"]],
                                      "onSuccessUpdateEmail": ["#send": ["mailboxIds/\(drafts)": NSNull(), "mailboxIds/\(sent)": true,
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
