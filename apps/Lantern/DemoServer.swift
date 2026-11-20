// Sample mail: a pretend JMAP server that lives inside the app, full of made up emails. "Try it with sample mail"
// on the welcome screen adds it as an account, so anyone (Apple's reviewers included) can try every feature
// without a Fastmail account. The App Store screenshots are taken from it too, so they never show real mail.
// Nothing here touches the network: requests to demo.jmapconnect.app are answered by DemoProtocol below.

import Foundation

enum Demo {
    static let host = "demo.jmapconnect.app"
    static let sessionURL = "https://demo.jmapconnect.app/jmap/session"
    static let kind = "demo"
    static let me = EmailAddress(name: "Sam Taylor", email: "sam@example.com")

    /// Launch arguments used by the screenshot workflow: -JCDemo adds sample mail, -JCScreen picks the screen.
    static var launchedForScreens: Bool { ProcessInfo.processInfo.arguments.contains("-JCDemo") }
    static var screen: String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-JCScreen"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
}

/// Answers the app's requests to the sample server, as if it were a real JMAP server across the internet.
final class DemoProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == Demo.host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = Self.body(of: request)
        let (status, data, type) = DemoServer.shared.respond(path: url.path, method: request.httpMethod ?? "GET",
                                                             body: body, contentType: request.value(forHTTPHeaderField: "Content-Type"))
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let b = request.httpBody { return b }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

final class DemoServer: @unchecked Sendable {
    static let shared = DemoServer()

    private struct Box { var id: String; var name: String; var role: String?; var parentId: String?; var sort: Int }
    private struct Mail {
        var id: String
        var threadId: String
        var mailboxIds: [String: Bool]
        var keywords: [String: Bool]
        var from: [EmailAddress]
        var to: [EmailAddress]
        var cc: [EmailAddress] = []
        var bcc: [EmailAddress] = []
        var replyTo: [EmailAddress]? = nil
        var subject: String
        var text: String
        var html: String? = nil
        var received: Date
        var files: [(blobId: String, name: String, type: String, size: Int)] = []
        var messageId: String
        var inReplyTo: String? = nil
        var references: [String] = []
    }
    private struct Who { var id: String; var name: String; var email: String; var signature: String; var replyTo: [EmailAddress]? }

    private let lock = NSLock()
    private var boxes: [Box] = []
    private var mails: [String: Mail] = [:]
    private var identities: [Who] = []
    private var blobs: [String: (Data, String)] = [:]
    private var counter = 0

    private init() { seed() }

    private func next(_ prefix: String) -> String { counter += 1; return "\(prefix)\(counter)" }

    // MARK: HTTP

    func respond(path: String, method: String, body: Data, contentType: String?) -> (Int, Data, String) {
        lock.lock(); defer { lock.unlock() }
        if path.hasSuffix("/session") { return (200, json(session()), "application/json") }
        if path.hasSuffix("/api") {
            guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let calls = root["methodCalls"] as? [[Any]] else { return (400, Data(), "text/plain") }
            return (200, json(["methodResponses": run(calls), "sessionState": "1"]), "application/json")
        }
        if path.contains("/upload/") {
            let id = next("up")
            let type = contentType ?? "application/octet-stream"
            blobs[id] = (body, type)
            return (200, json(["accountId": "demo", "blobId": id, "type": type, "size": body.count]), "application/json")
        }
        if path.contains("/download/") {
            // /jmap/download/{accountId}/{blobId}/{name}
            let parts = path.split(separator: "/").map(String.init)
            guard let i = parts.firstIndex(of: "download"), i + 2 < parts.count else { return (404, Data(), "text/plain") }
            let blobId = parts[i + 2].removingPercentEncoding ?? parts[i + 2]
            if let blob = blobs[blobId] { return (200, blob.0, blob.1) }
            if let m = mails.values.first(where: { "eml-" + $0.id == blobId }) { return (200, Data(eml(m).utf8), "message/rfc822") }
            return (404, Data(), "text/plain")
        }
        return (404, Data(), "text/plain")
    }

    private func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    private func json(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value)) ?? Data() }

    private func session() -> [String: Any] {
        [
            "apiUrl": "https://\(Demo.host)/jmap/api",
            "downloadUrl": "https://\(Demo.host)/jmap/download/{accountId}/{blobId}/{name}?type={type}",
            "uploadUrl": "https://\(Demo.host)/jmap/upload/{accountId}",
            "username": Demo.me.email,
            "primaryAccounts": [JMAPClient.mail: "demo", JMAPClient.submission: "demo"],
            "state": "1",
            "capabilities": [:] as [String: Any],
            "accounts": [:] as [String: Any]
        ]
    }

    // MARK: Methods

    private func run(_ calls: [[Any]]) -> [[Any]] {
        var out: [[Any]] = []
        var results: [String: [String: Any]] = [:]
        var created: [String: String] = [:]   // "#draft" style references made earlier in this request
        for call in calls where call.count == 3 {
            guard let name = call[0] as? String, var args = call[1] as? [String: Any], let id = call[2] as? String else { continue }
            for (key, value) in args where key.hasPrefix("#") {
                if let ref = value as? [String: Any] { args[String(key.dropFirst())] = resolve(ref, results) }
                args.removeValue(forKey: key)
            }
            let answer: [String: Any]
            switch name {
            case "Mailbox/get": answer = mailboxGet()
            case "Mailbox/set": answer = mailboxSet(args)
            case "Email/query": answer = emailQuery(args)
            case "Email/get": answer = emailGet(args)
            case "Thread/get": answer = threadGet(args)
            case "Identity/get": answer = ["accountId": "demo", "state": "1", "list": identities.map(identityJSON)]
            case "Identity/set": answer = identitySet(args)
            case "Email/set": answer = emailSet(args, &created)
            case "EmailSubmission/set": answer = submissionSet(args, &created)
            default:
                out.append(["error", ["type": "unknownMethod"], id])
                continue
            }
            results[id] = answer
            out.append([name, answer, id])
        }
        return out
    }

    private func resolve(_ ref: [String: Any], _ results: [String: [String: Any]]) -> Any {
        guard let of = ref["resultOf"] as? String, let path = ref["path"] as? String, let r = results[of] else { return [String]() }
        if path == "/ids" { return r["ids"] ?? [String]() }
        if path == "/list/*/emailIds" {
            return ((r["list"] as? [[String: Any]]) ?? []).flatMap { ($0["emailIds"] as? [String]) ?? [] }
        }
        return [String]()
    }

    private func mailboxGet() -> [String: Any] {
        let list: [[String: Any]] = boxes.map { b in
            let inside = mails.values.filter { $0.mailboxIds[b.id] == true }
            let unread = inside.filter { $0.keywords["$seen"] != true }
            return ["id": b.id, "name": b.name, "role": orNull(b.role), "parentId": orNull(b.parentId),
                    "sortOrder": b.sort, "totalEmails": inside.count, "unreadEmails": unread.count]
        }
        return ["accountId": "demo", "state": "1", "list": list, "notFound": [String]()]
    }

    private func mailboxSet(_ args: [String: Any]) -> [String: Any] {
        var created: [String: Any] = [:]
        var updated: [String: Any] = [:]
        for (key, value) in (args["create"] as? [String: [String: Any]]) ?? [:] {
            let id = next("box")
            boxes.append(Box(id: id, name: (value["name"] as? String) ?? "New folder", role: nil, parentId: value["parentId"] as? String, sort: 50))
            created[key] = ["id": id]
        }
        for (id, patch) in (args["update"] as? [String: [String: Any]]) ?? [:] {
            if let i = boxes.firstIndex(where: { $0.id == id }), let name = patch["name"] as? String { boxes[i].name = name }
            updated[id] = NSNull()
        }
        return ["accountId": "demo", "created": created, "updated": updated]
    }

    private func emailQuery(_ args: [String: Any]) -> [String: Any] {
        let filter = (args["filter"] as? [String: Any]) ?? [:]
        var found = Array(mails.values)
        if let box = filter["inMailbox"] as? String { found = found.filter { $0.mailboxIds[box] == true } }
        if let skip = filter["inMailboxOtherThan"] as? [String] { found = found.filter { m in !m.mailboxIds.keys.contains { skip.contains($0) } } }
        if let words = (filter["text"] as? String)?.lowercased(), !words.isEmpty {
            found = found.filter { m in
                ([m.subject, m.text] + m.from.map(\.full) + m.to.map(\.full)).contains { $0.lowercased().contains(words) }
            }
        }
        found.sort { $0.received > $1.received }
        if (args["collapseThreads"] as? Bool) == true {
            var seen = Set<String>()
            found = found.filter { seen.insert($0.threadId).inserted }
        }
        let position = (args["position"] as? Int) ?? 0
        let limit = (args["limit"] as? Int) ?? 100
        let ids = found.dropFirst(position).prefix(limit).map(\.id)
        return ["accountId": "demo", "queryState": "1", "position": position, "ids": Array(ids), "total": found.count]
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func addresses(_ list: [EmailAddress]) -> [[String: Any]] {
        list.map { ["name": orNull($0.name), "email": $0.email] as [String: Any] }
    }

    private func emailJSON(_ m: Mail) -> [String: Any] {
        var e: [String: Any] = [
            "id": m.id, "threadId": m.threadId, "mailboxIds": m.mailboxIds, "keywords": m.keywords,
            "from": addresses(m.from), "to": addresses(m.to), "cc": addresses(m.cc), "bcc": addresses(m.bcc),
            "subject": m.subject, "preview": String(m.text.replacingOccurrences(of: "\n", with: " ").prefix(160)),
            "receivedAt": Self.iso.string(from: m.received), "hasAttachment": !m.files.isEmpty,
            "messageId": [m.messageId], "references": m.references, "blobId": "eml-" + m.id,
            "textBody": [["partId": "t", "type": "text/plain"]],
            "htmlBody": [["partId": m.html == nil ? "t" : "h", "type": m.html == nil ? "text/plain" : "text/html"]],
            "attachments": m.files.map { ["partId": $0.blobId, "blobId": $0.blobId, "type": $0.type, "name": $0.name, "size": $0.size] }
        ]
        e["replyTo"] = orNull(m.replyTo.map(addresses))
        e["inReplyTo"] = orNull(m.inReplyTo.map { [$0] })
        var values: [String: Any] = ["t": ["value": m.text, "isTruncated": false]]
        if let html = m.html { values["h"] = ["value": html, "isTruncated": false] }
        e["bodyValues"] = values
        return e
    }

    private func emailGet(_ args: [String: Any]) -> [String: Any] {
        let ids = (args["ids"] as? [String]) ?? []
        let list = ids.compactMap { mails[$0] }.map(emailJSON)
        return ["accountId": "demo", "state": "1", "list": list, "notFound": ids.filter { mails[$0] == nil }]
    }

    private func threadGet(_ args: [String: Any]) -> [String: Any] {
        let ids = (args["ids"] as? [String]) ?? []
        let list: [[String: Any]] = ids.map { t in
            ["id": t, "emailIds": mails.values.filter { $0.threadId == t }.sorted { $0.received < $1.received }.map(\.id)]
        }
        return ["accountId": "demo", "state": "1", "list": list, "notFound": [String]()]
    }

    private func identityJSON(_ w: Who) -> [String: Any] {
        ["id": w.id, "name": w.name, "email": w.email, "textSignature": w.signature,
         "replyTo": orNull(w.replyTo.map(addresses)), "mayDelete": true]
    }

    private func identitySet(_ args: [String: Any]) -> [String: Any] {
        var created: [String: Any] = [:]
        var updated: [String: Any] = [:]
        for (key, value) in (args["create"] as? [String: [String: Any]]) ?? [:] {
            let id = next("id")
            identities.append(Who(id: id, name: (value["name"] as? String) ?? Demo.me.name ?? "", email: (value["email"] as? String) ?? "", signature: "", replyTo: nil))
            created[key] = ["id": id]
        }
        for (id, patch) in (args["update"] as? [String: [String: Any]]) ?? [:] {
            guard let i = identities.firstIndex(where: { $0.id == id }) else { continue }
            if let s = patch["textSignature"] as? String { identities[i].signature = s }
            if patch.keys.contains("replyTo") { identities[i].replyTo = Self.parse(patch["replyTo"]) }
            updated[id] = NSNull()
        }
        return ["accountId": "demo", "created": created, "updated": updated]
    }

    private static func parse(_ value: Any?) -> [EmailAddress]? {
        guard let list = value as? [[String: Any]] else { return nil }
        return list.compactMap { a in (a["email"] as? String).map { EmailAddress(name: a["name"] as? String, email: $0) } }
    }

    /// Applies a JMAP patch ("keywords/$seen": true, "mailboxIds/x": null, or whole "mailboxIds").
    private func apply(_ patch: [String: Any], to id: String) {
        guard var m = mails[id] else { return }
        for (key, value) in patch {
            if key == "mailboxIds", let v = value as? [String: Bool] { m.mailboxIds = v; continue }
            if key == "keywords", let v = value as? [String: Bool] { m.keywords = v; continue }
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let on = (value as? Bool) == true
            if parts[0] == "mailboxIds" { if on { m.mailboxIds[parts[1]] = true } else { m.mailboxIds.removeValue(forKey: parts[1]) } }
            if parts[0] == "keywords" { if on { m.keywords[parts[1]] = true } else { m.keywords.removeValue(forKey: parts[1]) } }
        }
        mails[id] = m
    }

    private func emailSet(_ args: [String: Any], _ made: inout [String: String]) -> [String: Any] {
        var created: [String: Any] = [:]
        var updated: [String: Any] = [:]
        for (key, v) in (args["create"] as? [String: [String: Any]]) ?? [:] {
            let id = next("m")
            let values = (v["bodyValues"] as? [String: [String: Any]]) ?? [:]
            let text = values.values.compactMap { $0["value"] as? String }.first ?? ""
            let inReplyTo = (v["inReplyTo"] as? [String])?.first
            let thread = inReplyTo.flatMap { r in mails.values.first { $0.messageId == r }?.threadId } ?? next("t")
            let files: [(blobId: String, name: String, type: String, size: Int)] = ((v["attachments"] as? [[String: Any]]) ?? []).map { a in
                let blob = (a["blobId"] as? String) ?? ""
                return (blob, (a["name"] as? String) ?? "File", (a["type"] as? String) ?? "application/octet-stream", blobs[blob]?.0.count ?? 0)
            }
            mails[id] = Mail(id: id, threadId: thread, mailboxIds: (v["mailboxIds"] as? [String: Bool]) ?? [:],
                             keywords: (v["keywords"] as? [String: Bool]) ?? [:], from: Self.parse(v["from"]) ?? [Demo.me],
                             to: Self.parse(v["to"]) ?? [], cc: Self.parse(v["cc"]) ?? [], bcc: Self.parse(v["bcc"]) ?? [],
                             replyTo: Self.parse(v["replyTo"]), subject: (v["subject"] as? String) ?? "", text: text,
                             received: Date(), files: files, messageId: "\(id)@demo.jmapconnect.app",
                             inReplyTo: inReplyTo, references: (v["references"] as? [String]) ?? [])
            made["#" + key] = id
            created[key] = ["id": id, "threadId": thread, "blobId": "eml-" + id, "size": text.utf8.count]
        }
        for (id, patch) in (args["update"] as? [String: [String: Any]]) ?? [:] {
            apply(patch, to: made[id] ?? id)
            updated[id] = NSNull()
        }
        let destroyed = ((args["destroy"] as? [String]) ?? []).filter { mails.removeValue(forKey: $0) != nil }
        return ["accountId": "demo", "created": created, "updated": updated, "destroyed": destroyed]
    }

    /// "Sends" an email: it never leaves the app, it just files itself in Sent, the way a real server would.
    private func submissionSet(_ args: [String: Any], _ made: inout [String: String]) -> [String: Any] {
        var created: [String: Any] = [:]
        for (key, v) in (args["create"] as? [String: [String: Any]]) ?? [:] {
            let ref = (v["emailId"] as? String) ?? ""
            let emailId = made[ref] ?? ref
            created[key] = ["id": next("sub")]
            if let patch = (args["onSuccessUpdateEmail"] as? [String: [String: Any]])?["#" + key] { apply(patch, to: emailId) }
        }
        return ["accountId": "demo", "created": created]
    }

    private func eml(_ m: Mail) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return """
        From: \(m.from.map(\.full).joined(separator: ", "))\r
        To: \(m.to.map(\.full).joined(separator: ", "))\r
        Subject: \(m.subject)\r
        Date: \(f.string(from: m.received))\r
        Message-ID: <\(m.messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        \(m.text.replacingOccurrences(of: "\n", with: "\r\n"))
        """
    }

    // MARK: Sample mail

    private func seed() {
        boxes = [
            Box(id: "inbox", name: "Inbox", role: "inbox", parentId: nil, sort: 1),
            Box(id: "drafts", name: "Drafts", role: "drafts", parentId: nil, sort: 2),
            Box(id: "sent", name: "Sent", role: "sent", parentId: nil, sort: 3),
            Box(id: "archive", name: "Archive", role: "archive", parentId: nil, sort: 4),
            Box(id: "junk", name: "Spam", role: "junk", parentId: nil, sort: 5),
            Box(id: "trash", name: "Trash", role: "trash", parentId: nil, sort: 6),
            Box(id: "clients", name: "Clients", role: nil, parentId: nil, sort: 10),
            Box(id: "receipts", name: "Receipts", role: nil, parentId: nil, sort: 11),
            Box(id: "travel", name: "Travel", role: nil, parentId: nil, sort: 12),
            Box(id: "japan", name: "Japan 2027", role: nil, parentId: "travel", sort: 13)
        ]
        identities = [
            Who(id: "sam", name: "Sam Taylor", email: Demo.me.email, signature: "Sam Taylor\nNorthwind Studio", replyTo: nil),
            Who(id: "studio", name: "Northwind Studio", email: "*@northwind.example", signature: "Northwind Studio\nnorthwind.example", replyTo: nil)
        ]
        blobs["pdf1"] = (Self.pdf, "application/pdf")
        blobs["png1"] = (Self.png, "image/png")
        blobs["pdf2"] = (Self.pdf, "application/pdf")

        let maya = EmailAddress(name: "Maya Chen", email: "maya@studio-north.example")
        let tom = EmailAddress(name: "Tom Okafor", email: "tom@okafor.example")
        let leo = EmailAddress(name: "Leo Park", email: "leo@parkfamily.example")
        let ana = EmailAddress(name: "Ana Rodrigues", email: "ana@rodrigues-law.example")
        let studio = EmailAddress(name: "Sam Taylor", email: "hello@northwind.example")
        let now = Date()
        let cal = Calendar.current
        func at(_ daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
            let day = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            let d = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
            // Today's sample mail is never in the future, whatever time the app is opened.
            return d > now ? now.addingTimeInterval(-Double(60 * (12 - min(hour, 11)))) : d
        }
        var n = 0
        func add(_ box: String, _ from: EmailAddress, to: [EmailAddress] = [Demo.me], cc: [EmailAddress] = [], _ subject: String,
                 _ text: String, html: String? = nil, _ when: Date, read: Bool = true, starred: Bool = false,
                 files: [(String, String, String, Int)] = [], thread: String? = nil, replyTo: String? = nil) -> Mail {
            n += 1
            let id = "s\(n)"
            var k: [String: Bool] = [:]
            if read { k["$seen"] = true }
            if starred { k["$flagged"] = true }
            if box == "drafts" { k["$draft"] = true }
            let m = Mail(id: id, threadId: thread ?? "t-\(id)", mailboxIds: [box: true], keywords: k, from: [from], to: to, cc: cc,
                         subject: subject, text: text, html: html, received: when,
                         files: files.map { (blobId: $0.0, name: $0.1, type: $0.2, size: $0.3) },
                         messageId: "\(id)@sample.example", inReplyTo: replyTo, references: replyTo.map { [$0] } ?? [])
            mails[id] = m
            return m
        }

        _ = add("inbox", maya, "Sketches for the spring launch", """
        Hi Sam,

        Here are the three directions we talked about on Monday. I think the second one has the most energy, but the first is the safest for print.

        The moodboard shows the colours side by side. If you can pick one by Friday, we'll have finished artwork the week after.

        Thanks,
        Maya
        """, at(0, 9, 42), read: false, files: [("pdf1", "spring-directions.pdf", "application/pdf", 2_400_000), ("png1", "moodboard.png", "image/png", 860_000)])
        _ = add("inbox", tom, "Saturday plans", """
        Still on for the climb? I've booked the 10am slot and the café after, if the weather holds.

        Tom
        """, at(0, 9, 15), read: false, starred: true)
        _ = add("inbox", EmailAddress(name: "Kestrel Bank", email: "statements@kestrel-bank.example"), "Your November statement is ready", """
        Hello Sam,

        Your statement for November is ready to view in the app. Nothing needs doing right now.

        Kestrel Bank
        """, at(0, 8, 3))
        _ = add("inbox", ana, "Contract, signed copy attached", """
        Hi Sam,

        All signed on our side. A copy is attached for your records, and the invoice will follow.

        Best wishes,
        Ana
        """, at(1, 16, 20), files: [("pdf2", "Northwind contract (signed).pdf", "application/pdf", 312_000)])
        _ = add("inbox", EmailAddress(name: "Hillside Books", email: "orders@hillside-books.example"), "Your order is on its way", """
        Good news: your books left us this morning and should be with you by Friday.
        """, html: """
        <div style="font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:560px;margin:0 auto;color:#2b2b2b">
        <div style="background:#2f5d50;color:#fff;padding:22px 26px;border-radius:12px 12px 0 0;font-size:20px;font-weight:600">Hillside Books</div>
        <div style="border:1px solid #e3e3e3;border-top:0;padding:24px 26px;border-radius:0 0 12px 12px">
        <p style="font-size:17px;margin:0 0 12px">Good news: your books left us this morning.</p>
        <p style="margin:0 0 18px;color:#555">They should be with you by Friday.</p>
        <table style="width:100%;border-collapse:collapse;font-size:15px">
        <tr><td style="padding:8px 0;border-bottom:1px solid #eee">The Overstory</td><td style="text-align:right;border-bottom:1px solid #eee">£10.99</td></tr>
        <tr><td style="padding:8px 0;border-bottom:1px solid #eee">A Field Guide to Getting Lost</td><td style="text-align:right;border-bottom:1px solid #eee">£9.99</td></tr>
        <tr><td style="padding:8px 0;font-weight:600">Total</td><td style="text-align:right;font-weight:600">£20.98</td></tr>
        </table>
        </div></div>
        """, at(1, 11, 5))
        let lisbon = add("sent", studio, to: [leo], "Lisbon in April", """
        Hi Leo,

        Are we still thinking Lisbon for the April trip? I'm free from the 14th.

        Sam
        """, at(3, 18, 30))
        _ = add("inbox", leo, "Re: Lisbon in April", """
        Flights look good for the 14th. Shall I hold the apartment near the river for four nights?

        Leo
        """, at(2, 10, 12), thread: lisbon.threadId, replyTo: lisbon.messageId)
        _ = add("inbox", EmailAddress(name: "Priya Shah", email: "priya@brightwell.example"), "Notes from Tuesday's review", """
        Hi Sam,

        Thanks for a great session. I've written up the three actions we agreed, with owners and dates, so nothing slips before the launch.

        Speak soon,
        Priya
        """, at(3, 14, 48))
        _ = add("inbox", EmailAddress(name: "Northwind Coffee", email: "hello@northwind-coffee.example"), "Your loyalty card is full", """
        Your next coffee is on us. Show this email at the counter any time this month.
        """, at(4, 7, 55))
        _ = add("clients", EmailAddress(name: "Jonas Weber", email: "jonas@weber-design.example"), "Website copy, second round", """
        Hi Sam, the second round of copy is in the shared folder. Only the About page has big changes.
        """, at(5, 15, 2))
        _ = add("clients", maya, "Invoice 2026-114", "Attached as usual. Thanks again for the quick turnaround.", at(9, 12, 0))
        _ = add("receipts", EmailAddress(name: "Rail Booking", email: "tickets@railbooking.example"), "Your tickets for 21 November", "London to Bristol, 08:30, coach C seat 42.", at(6, 20, 10))
        _ = add("travel", leo, "Packing list", "Sun cream, walking shoes and the good camera. Anything I've missed?", at(12, 19, 0))
        _ = add("japan", EmailAddress(name: "Sakura Ryokan", email: "stay@sakura-ryokan.example"), "Your stay in Kyoto is confirmed", "We look forward to welcoming you on 3 April 2027 for three nights.", at(14, 6, 30))
        _ = add("archive", tom, "Climbing photos", "A few of the better ones from last weekend. You look far braver than you were.", at(16, 21, 4))
        _ = add("junk", EmailAddress(name: "Prize Desk", email: "winner@prize-desk.example"), "You've won a luxury cruise!!!", "Claim your prize today by confirming your bank details.", at(1, 3, 12), read: false)
        _ = add("drafts", Demo.me, to: [EmailAddress(name: "Priya Shah", email: "priya@brightwell.example")], "Launch timings", """
        Hi Priya,

        Quick thought on the launch timings: could we move the press preview to the Wednesday?
        """, at(0, 7, 40))
    }

    /// A one page PDF, so sample attachments open in Quick Look.
    private static let pdf: Data = {
        let content = "BT /F1 24 Tf 72 720 Td (Sample attachment) Tj ET"
        var s = "%PDF-1.4\n"
        var offsets: [Int] = []
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ]
        for (i, o) in objects.enumerated() {
            offsets.append(s.utf8.count)
            s += "\(i + 1) 0 obj\n\(o)\nendobj\n"
        }
        let xref = s.utf8.count
        s += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { s += String(format: "%010d 00000 n \n", o) }
        s += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(s.utf8)
    }()

    /// A small plum square, for the sample picture attachment.
    private static let png: Data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==") ?? Data()
}
