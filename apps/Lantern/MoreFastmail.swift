// JMAP Connect 1.2: the Fastmail extras (Paul, 19 Nov 2026). Each one shows only where the server says it can do it:
//   Send later      EmailSubmission held until a time (submission capability maxDelayedSend > 0)
//   Out of office   VacationResponse (RFC 8621 section 8)
//   Unsubscribe     List-Unsubscribe and List-Unsubscribe-Post headers (RFC 2369, RFC 8058 one click)
//   Contacts        ContactCard (RFC 9610), for filling in To, Cc and Bcc

import Foundation

struct Vacation: Equatable {
    var on = false
    var from: Date?
    var to: Date?
    var subject = ""
    var text = ""
}

struct Unsubscribe: Equatable {
    /// An https address that unsubscribes with one POST (RFC 8058), with no web page to fill in.
    var oneClick: URL?
    /// A web page to open.
    var web: URL?
    /// An address to email.
    var mail: String?

    var any: Bool { oneClick != nil || web != nil || mail != nil }
}

struct Contact: Hashable, Identifiable {
    let name: String
    let email: String
    var id: String { email.lowercased() }
    var line: String { name.isEmpty ? email : "\(name) <\(email)>" }
}

extension JMAPClient {
    static let vacation = "urn:ietf:params:jmap:vacationresponse"
    static let contacts = "urn:ietf:params:jmap:contacts"

    static func utc(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    static func date(_ text: Any?) -> Date? {
        guard let text = text as? String else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text)
    }

    // MARK: Send later

    /// How far ahead the server will hold an email, in seconds. 0 means it won't.
    var maxDelayedSend: Int {
        ((accountCapabilities[Self.submission] as? [String: Any])?["maxDelayedSend"] as? NSNumber)?.intValue ?? 0
    }

    // MARK: Out of office

    var canVacation: Bool { capabilities[Self.vacation] != nil && session?.primaryAccounts[Self.vacation] != nil }

    func vacationResponse() async throws -> Vacation {
        if session == nil { try await connect() }
        guard let acc = session?.primaryAccounts[Self.vacation] else { throw JMAPError.missing("out of office") }
        let r = try await call([["VacationResponse/get", ["accountId": acc, "ids": ["singleton"]], "v"]], using: [Self.core, Self.vacation])
        guard let v = (r["v"]?["list"] as? [[String: Any]])?.first else { return Vacation() }
        return Vacation(on: v["isEnabled"] as? Bool ?? false, from: Self.date(v["fromDate"]), to: Self.date(v["toDate"]),
                        subject: v["subject"] as? String ?? "", text: v["textBody"] as? String ?? "")
    }

    func setVacationResponse(_ v: Vacation) async throws {
        if session == nil { try await connect() }
        guard let acc = session?.primaryAccounts[Self.vacation] else { throw JMAPError.missing("out of office") }
        let patch: [String: Any] = [
            "isEnabled": v.on,
            "fromDate": v.from.map { Self.utc($0) as Any } ?? NSNull(),
            "toDate": v.to.map { Self.utc($0) as Any } ?? NSNull(),
            "subject": v.subject.isEmpty ? (NSNull() as Any) : (v.subject as Any),
            "textBody": v.text,
            "htmlBody": NSNull(),
        ]
        let r = try await call([["VacationResponse/set", ["accountId": acc, "update": ["singleton": patch]], "v"]], using: [Self.core, Self.vacation])
        if let failed = (r["v"]?["notUpdated"] as? [String: Any])?["singleton"] as? [String: Any] {
            throw JMAPError.method(failed["type"] as? String ?? "notUpdated", failed["description"] as? String)
        }
    }

    // MARK: Unsubscribe

    func unsubscribe(for id: String) async throws -> Unsubscribe {
        guard let acc = accountId else { throw JMAPError.missing("an account") }
        let r = try await call([["Email/get", ["accountId": acc, "ids": [id],
                                               "properties": ["header:List-Unsubscribe:asURLs:all", "header:List-Unsubscribe-Post:asText"]], "u"]])
        guard let first = (r["u"]?["list"] as? [[String: Any]])?.first else { return Unsubscribe() }
        let urls = ((first["header:List-Unsubscribe:asURLs:all"] as? [Any]) ?? []).flatMap { ($0 as? [String]) ?? [] }
        let post = (first["header:List-Unsubscribe-Post:asText"] as? String ?? "").replacingOccurrences(of: " ", with: "")
        var out = Unsubscribe()
        for text in urls {
            guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)) else { continue }
            switch url.scheme?.lowercased() {
            case "https":
                if post.localizedCaseInsensitiveContains("List-Unsubscribe=One-Click") { out.oneClick = out.oneClick ?? url }
                out.web = out.web ?? url
            case "http":
                out.web = out.web ?? url
            case "mailto":
                let address = url.absoluteString.dropFirst("mailto:".count).split(separator: "?").first.map(String.init) ?? ""
                if address.contains("@") { out.mail = out.mail ?? (address.removingPercentEncoding ?? address) }
            default: break
            }
        }
        return out
    }

    /// RFC 8058: one POST with a fixed body, and nothing else. No token, no cookies.
    static func oneClickUnsubscribe(_ url: URL) async throws {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpShouldHandleCookies = false
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        r.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<400).contains(code) else { throw JMAPError.http(code) }
    }

    // MARK: Contacts

    var canContacts: Bool { session?.primaryAccounts[Self.contacts] != nil }

    /// Everyone in the address book with an email address.
    func contactList() async throws -> [Contact] {
        if session == nil { try await connect() }
        guard let acc = session?.primaryAccounts[Self.contacts] else { return [] }
        let r = try await call([["ContactCard/get", ["accountId": acc, "properties": ["name", "emails"]], "c"]], using: [Self.core, Self.contacts])
        var out: [Contact] = []
        for card in (r["c"]?["list"] as? [[String: Any]]) ?? [] {
            let n = card["name"] as? [String: Any]
            var name = n?["full"] as? String ?? ""
            if name.isEmpty, let parts = n?["components"] as? [[String: Any]] {
                name = parts.filter { ["given", "surname", "given2", "surname2"].contains($0["kind"] as? String ?? "") }
                    .compactMap { $0["value"] as? String }.joined(separator: " ")
            }
            for value in ((card["emails"] as? [String: Any]) ?? [:]).values {
                if let address = (value as? [String: Any])?["address"] as? String, address.contains("@") {
                    out.append(Contact(name: name, email: address))
                }
            }
        }
        return out
    }
}

// MARK: Scheduled emails

/// An email waiting in Fastmail's Scheduled folder: when it goes, and the submission that sends it.
struct Waiting {
    let submissionId: String
    let sendAt: Date?
}

extension JMAPClient {
    /// The submissions for these emails, by email id, as (id, undoStatus, sendAt).
    private func submissions(for emailIds: [String]) async throws -> [String: [(id: String, status: String, sendAt: Date?)]] {
        guard let acc = accountId, !emailIds.isEmpty else { return [:] }
        let r = try await call([
            ["EmailSubmission/query", ["accountId": acc, "filter": ["emailIds": emailIds]], "q"],
            ["EmailSubmission/get", ["accountId": acc, "#ids": ["resultOf": "q", "name": "EmailSubmission/query", "path": "/ids"],
                                     "properties": ["emailId", "undoStatus", "sendAt"]], "g"],
        ], using: [Self.core, Self.mail, Self.submission])
        var out: [String: [(id: String, status: String, sendAt: Date?)]] = [:]
        for s in (r["g"]?["list"] as? [[String: Any]]) ?? [] {
            guard let id = s["id"] as? String, let email = s["emailId"] as? String else { continue }
            out[email, default: []].append((id, s["undoStatus"] as? String ?? "", Self.date(s["sendAt"])))
        }
        return out
    }

    /// Emails in Scheduled that Fastmail has now sent move on to Sent, where you'd look for them.
    func releaseScheduled(scheduled: String, sent: String) async throws {
        guard let acc = accountId else { return }
        let q = try await call([["Email/query", ["accountId": acc, "filter": ["inMailbox": scheduled], "limit": 100], "q"]])
        let ids = (q["q"]?["ids"] as? [String]) ?? []
        let subs = try await submissions(for: ids)
        let gone = ids.filter { id in
            guard let list = subs[id], !list.isEmpty else { return false }
            return list.allSatisfy { $0.status == "final" }
        }
        guard !gone.isEmpty else { return }
        var update: [String: Any] = [:]
        for id in gone { update[id] = ["mailboxIds/\(scheduled)": NSNull() as Any, "mailboxIds/\(sent)": true as Any] }
        _ = try await call([["Email/set", ["accountId": acc, "update": update], "u"]])
    }

    /// The pending send for this email, if it's still waiting to go.
    func waiting(_ emailId: String) async throws -> Waiting? {
        guard let s = try await submissions(for: [emailId])[emailId]?.first(where: { $0.status == "pending" }) else { return nil }
        return Waiting(submissionId: s.id, sendAt: s.sendAt)
    }

    /// Stops a scheduled email going and puts it back in Drafts, so it can be changed and sent again.
    func cancelScheduled(_ emailId: String, waiting: Waiting, scheduled: String?, drafts: String) async throws {
        guard let acc = accountId else { return }
        var boxes: [String: Any] = ["mailboxIds/\(drafts)": true as Any, "keywords/$draft": true as Any]
        if let scheduled { boxes["mailboxIds/\(scheduled)"] = NSNull() as Any }
        let r = try await call([
            ["EmailSubmission/set", ["accountId": acc, "update": [waiting.submissionId: ["undoStatus": "canceled"]]], "c"],
        ], using: [Self.core, Self.mail, Self.submission])
        if let failed = r["c"]?["notUpdated"] as? [String: Any], let first = failed.values.first as? [String: Any] {
            throw JMAPError.method(first["type"] as? String ?? "notUpdated", first["description"] as? String)
        }
        _ = try await call([["Email/set", ["accountId": acc, "update": [emailId: boxes]], "u"]])
    }
}
