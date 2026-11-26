// What Lantern knows about mail: the JMAP shapes it reads (addresses, folders, identities, emails, attachments)
// and how dates are shown.

import Foundation

struct EmailAddress: Codable, Hashable {
    var name: String?
    var email: String

    var display: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return email
    }
    var initials: String {
        let words = display.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(2)
        let letters = words.compactMap { $0.first }.map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }
    /// "Maya Chen <maya@example.com>", for the To and Cc boxes.
    var full: String { name.map { n in n.isEmpty ? email : "\(n) <\(email)>" } ?? email }

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

    /// The usual folders first, in the order every mail app uses, then the person's own folders A to Z.
    var rank: Int {
        switch role {
        case "inbox": return 0
        case "drafts": return 1
        case "sent": return 2
        case "archive": return 3
        case "junk": return 4
        case "trash": return 5
        default: return 10
        }
    }

    var icon: String {
        switch role {
        case "inbox": return "tray"
        case "drafts": return "doc"
        case "sent": return "paperplane"
        case "archive": return "archivebox"
        case "junk": return "xmark.bin"
        case "trash": return "trash"
        default: return "folder"
        }
    }

    /// Unread counts matter in the inbox and your own folders, not in Sent, Trash or Spam.
    var showsUnread: Bool { !["sent", "trash", "junk", "drafts", "archive"].contains(role ?? "") }
}

struct Identity: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let email: String
    var textSignature: String?
    var replyTo: [EmailAddress]?

    /// Fastmail lets you send from every address at a domain with one identity, written *@example.com.
    var isWildcard: Bool { email.hasPrefix("*@") }
    var domain: String { email.split(separator: "@").last.map { String($0).lowercased() } ?? "" }
    /// Whether this identity may send as the address.
    func covers(_ address: String) -> Bool {
        let a = address.lowercased()
        return isWildcard ? a.hasSuffix("@" + domain) && a.count > domain.count + 1 : a == email.lowercased()
    }
    var label: String {
        let shown = isWildcard ? "any address @\(domain)" : email
        return name.isEmpty ? shown : "\(name) <\(shown)>"
    }
    var replyToText: String { (replyTo ?? []).map(\.full).joined(separator: ", ") }
}

/// A file you've added to an email you're writing, once it's on the server.
struct Outgoing: Identifiable, Hashable {
    let blobId: String
    let name: String
    let type: String
    let size: Int
    var id: String { blobId }
}

/// A file attached to an email.
struct Attachment: Identifiable, Hashable {
    let blobId: String
    let name: String
    let type: String
    let size: Int
    var id: String { blobId }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
    var icon: String {
        let t = type.lowercased()
        if t.hasPrefix("image/") { return "photo" }
        if t.contains("pdf") { return "doc.richtext" }
        if t.contains("zip") || t.contains("compressed") { return "doc.zipper" }
        if t.contains("calendar") { return "calendar" }
        return "doc"
    }
}

struct Email: Codable, Identifiable, Hashable {
    let id: String
    let threadId: String
    let mailboxIds: [String: Bool]
    let keywords: [String: Bool]?
    let from: [EmailAddress]?
    let to: [EmailAddress]?
    let cc: [EmailAddress]?
    let replyTo: [EmailAddress]?
    let subject: String?
    let preview: String?
    let receivedAt: String
    let hasAttachment: Bool?
    let messageId: [String]?
    let references: [String]?
    let blobId: String?
    var bcc: [EmailAddress]? = nil
    var inReplyTo: [String]? = nil

    static let listProperties = ["id", "threadId", "mailboxIds", "keywords", "from", "to", "cc", "replyTo", "subject",
                                 "preview", "receivedAt", "hasAttachment", "messageId", "references", "blobId", "bcc", "inReplyTo"]

    var sender: EmailAddress { from?.first ?? EmailAddress(name: "Unknown sender", email: "") }
    var isUnread: Bool { keywords?["$seen"] != true }
    var isFlagged: Bool { keywords?["$flagged"] == true }
    /// Muted conversation: Fastmail keeps later replies out of the inbox.
    var isMuted: Bool { keywords?["$muted"] == true }
    var isDraft: Bool { keywords?["$draft"] == true }
    var title: String { (subject?.isEmpty == false ? subject : nil) ?? "(No subject)" }
    var date: Date { Email.iso.date(from: receivedAt) ?? Email.isoPlain.date(from: receivedAt) ?? .distantPast }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain = ISO8601DateFormatter()
}

enum When {
    /// In English, dates look as they always have ("Mon 12 Nov 2025 at 09:42"). In another language the same parts
    /// come in that language's own order and words.
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        if (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("en") {
            f.locale = Locale(identifier: "en_GB")
            f.dateFormat = format
        } else {
            f.locale = .current
            f.setLocalizedDateFormatFromTemplate(format.replacingOccurrences(of: "'at'", with: "").replacingOccurrences(of: " ", with: ""))
        }
        return f
    }
    private static let time = formatter("HH:mm")
    private static let day = formatter("EEE")
    private static let date = formatter("d MMM")
    private static let dateYear = formatter("d MMM yyyy")
    private static let full = formatter("EEE d MMM yyyy 'at' HH:mm")

    /// "09:42", "Yesterday", "Mon", "12 Nov", "12 Nov 2025".
    static func short(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return time.string(from: d) }
        if cal.isDateInYesterday(d) { return String(localized: "Yesterday") }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 { return day.string(from: d) }
        if cal.component(.year, from: d) == cal.component(.year, from: Date()) { return date.string(from: d) }
        return dateYear.string(from: d)
    }

    /// "Wed 18 Nov 2026 at 10:47", in the reading pane and in quoted replies.
    static func long(_ d: Date) -> String { full.string(from: d) }
}
