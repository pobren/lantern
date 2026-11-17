// What Lantern knows about mail: the JMAP shapes it reads, plus the small judgements it makes about them
// (who a message is from, whether it needs you, whether it's something to read later).

import Foundation

struct EmailAddress: Codable, Hashable {
    var name: String?
    var email: String

    var display: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return email
    }
    var firstName: String { display.split(separator: " ").first.map(String.init) ?? display }
    var initials: String {
        let words = display.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(2)
        let letters = words.compactMap { $0.first }.map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }

    /// Reads "Maya Chen <maya@example.com>, tom@example.com" into addresses.
    static func parse(_ text: String) -> [EmailAddress] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" }).compactMap { part in
            let s = part.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return nil }
            if let lt = s.firstIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
                let name = s[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                let email = String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
                return email.contains("@") ? EmailAddress(name: name.isEmpty ? nil : name, email: email) : nil
            }
            return s.contains("@") ? EmailAddress(name: nil, email: s) : nil
        }
    }
}

struct Mailbox: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let role: String?
    let parentId: String?
    let sortOrder: Int?
    let totalEmails: Int?
    let unreadEmails: Int?
}

struct Identity: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let email: String
    var label: String { name.isEmpty ? email : "\(name), \(email)" }
}

struct Email: Codable, Identifiable, Hashable {
    let id: String
    let threadId: String
    let mailboxIds: [String: Bool]
    let keywords: [String: Bool]?
    let from: [EmailAddress]?
    let to: [EmailAddress]?
    let cc: [EmailAddress]?
    let subject: String?
    let preview: String?
    let receivedAt: String
    let hasAttachment: Bool?
    let messageId: [String]?
    let listUnsubscribe: String?

    enum CodingKeys: String, CodingKey {
        case id, threadId, mailboxIds, keywords, from, to, cc, subject, preview, receivedAt, hasAttachment, messageId
        case listUnsubscribe = "header:List-Unsubscribe:asText"
    }

    static let listProperties = ["id", "threadId", "mailboxIds", "keywords", "from", "to", "cc", "subject", "preview",
                                 "receivedAt", "hasAttachment", "messageId", "header:List-Unsubscribe:asText"]

    var sender: EmailAddress { from?.first ?? EmailAddress(name: "Unknown sender", email: "") }
    var isUnread: Bool { keywords?["$seen"] != true }
    var isFlagged: Bool { keywords?["$flagged"] == true }
    var title: String { (subject?.isEmpty == false ? subject : nil) ?? "(No subject)" }
    var date: Date { Email.iso.date(from: receivedAt) ?? Email.isoPlain.date(from: receivedAt) ?? .distantPast }

    /// Newsletters and mailing lists carry List-Unsubscribe: those go to "For later reading", never "Needs you".
    var isBulk: Bool { listUnsubscribe != nil }

    /// Receipts, tickets, alerts: sent by a machine to you, not a person writing to you.
    var isAutomated: Bool {
        let e = sender.email.lowercased()
        let local = e.split(separator: "@").first.map(String.init) ?? e
        let robots = ["noreply", "no-reply", "donotreply", "do-not-reply", "notifications", "notification", "alerts",
                      "receipts", "billing", "invoice", "orders", "support", "info", "hello", "news", "updates", "mailer-daemon"]
        return robots.contains(where: { local == $0 || local.hasPrefix($0 + "+") || local.hasPrefix($0 + "-") })
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain = ISO8601DateFormatter()
}

/// The three piles on the Today screen.
enum Pile: String, CaseIterable {
    case needsYou = "Needs you"
    case updates = "Updates and receipts"
    case reading = "For later reading"

    static func of(_ e: Email) -> Pile {
        if e.isBulk { return .reading }
        if e.isAutomated { return .updates }
        return .needsYou
    }
}

/// One person you write to, with the emails between you.
struct Person: Identifiable, Hashable {
    var id: String { address.email.lowercased() }
    let address: EmailAddress
    var emails: [Email]
    var latest: Email? { emails.max(by: { $0.date < $1.date }) }
    var unread: Int { emails.filter { $0.isUnread }.count }
}

enum When {
    private static let time: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "HH:mm"; return f }()
    private static let day: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEE"; return f }()
    private static let date: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "d MMM"; return f }()
    private static let long: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEEE d MMMM"; return f }()

    /// "09:42", "Yesterday", "Mon", "12 Nov".
    static func short(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return time.string(from: d) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 { return day.string(from: d) }
        return date.string(from: d)
    }

    static func today() -> String { long.string(from: Date()).uppercased() }

    static func greeting() -> String {
        let h = Calendar.current.component(.hour, from: Date())
        if h < 12 { return "Good morning" }
        if h < 18 { return "Good afternoon" }
        return "Good evening"
    }
}
