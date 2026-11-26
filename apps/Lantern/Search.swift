// Search that explains itself (Paul, 20 Nov 2026: "it brings up results but you can't tell why").
//
// - Words like from:, to:, subject:, has:attachment, is:unread and is:starred narrow the search, the way
//   Fastmail's own search box works. Everything else is searched for anywhere in the email.
// - Each result says where it matched (From, To, Subject, or the message itself) and the matching words are bold.
// - While you type, suggestions offer people from your contacts ("From Maya", "To Maya"), an address you're typing,
//   the narrowing words, and your recent searches.

import SwiftUI

struct SearchQuery: Equatable {
    var from: [String] = []
    var to: [String] = []
    var subject: [String] = []
    var hasAttachment = false
    var unread = false
    var starred = false
    /// Words to find anywhere.
    var words: [String] = []

    /// True when the search uses from:, to: and the like (saved mail can't answer those; the server does).
    var narrowed: Bool { !from.isEmpty || !to.isEmpty || !subject.isEmpty || hasAttachment || unread || starred }
    var freeText: String { words.joined(separator: " ") }

    init(_ typed: String) {
        for part in SearchQuery.split(typed) {
            let lower = part.lowercased()
            func value(_ prefix: String) -> String? {
                guard lower.hasPrefix(prefix) else { return nil }
                let v = String(part.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return v.isEmpty ? nil : v
            }
            if let v = value("from:") { from.append(v) }
            else if let v = value("to:") { to.append(v) }
            else if let v = value("subject:") { subject.append(v) }
            else if lower == "has:attachment" || lower == "has:attachments" { hasAttachment = true }
            else if lower == "is:unread" { unread = true }
            else if lower == "is:starred" || lower == "is:flagged" { starred = true }
            else { words.append(part.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) }
        }
    }

    /// Splits on spaces, keeping "quoted words" together (from:"Maya Chen").
    static func split(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        for c in text {
            if c == "\"" { quoted.toggle(); current.append(c) }
            else if c == " " && !quoted { if !current.isEmpty { parts.append(current); current = "" } }
            else { current.append(c) }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// The JMAP Email/query filter for this search, joined with whatever else the list needs (a folder, say).
    func filter(adding base: [String: Any]) -> [String: Any] {
        var conditions: [[String: Any]] = []
        if !base.isEmpty { conditions.append(base) }
        conditions += from.map { ["from": $0] }
        conditions += to.map { ["to": $0] }
        conditions += subject.map { ["subject": $0] }
        if hasAttachment { conditions.append(["hasAttachment": true]) }
        if unread { conditions.append(["notKeyword": "$seen"]) }
        if starred { conditions.append(["hasKeyword": "$flagged"]) }
        if !words.isEmpty { conditions.append(["text": freeText]) }
        if conditions.count == 1 { return conditions[0] }
        return ["operator": "AND", "conditions": conditions]
    }

    /// Where an email matched, for the line under each result.
    func reasons(_ e: Email) -> [String] {
        var found: [String] = []
        func has(_ text: String?, _ word: String) -> Bool { text?.localizedCaseInsensitiveContains(word) == true }
        func inPeople(_ list: [EmailAddress]?, _ word: String) -> Bool {
            (list ?? []).contains { has($0.name, word) || has($0.email, word) }
        }
        let terms = words + from + to + subject
        if !from.isEmpty || words.contains(where: { inPeople(e.from, $0) }) { found.append("From") }
        if !to.isEmpty || words.contains(where: { inPeople(e.to, $0) || inPeople(e.cc, $0) }) { found.append("To") }
        if !subject.isEmpty || words.contains(where: { has(e.subject, $0) }) { found.append("Subject") }
        if words.contains(where: { has(e.preview, $0) }) { found.append("Message") }
        if hasAttachment { found.append("Attachment") }
        if found.isEmpty && !terms.isEmpty { found.append("Message (further down)") }
        return found
    }

    /// The words to show in bold in a result.
    var highlights: [String] { (words + subject).filter { $0.count > 1 } }
}

extension Text {
    /// Text with every match of the given words in bold, so you can see why a result came up.
    static func highlighting(_ text: String, _ words: [String]) -> Text {
        var a = AttributedString(text)
        for w in words {
            var range = a.startIndex..<a.endIndex
            while let found = a[range].range(of: w, options: .caseInsensitive) {
                a[found].inlinePresentationIntent = .stronglyEmphasized
                a[found].foregroundColor = Look.accent
                range = found.upperBound..<a.endIndex
            }
        }
        return Text(a)
    }
}

/// One suggestion under the search box.
struct SearchSuggestion: Identifiable, Hashable {
    let id: String
    let icon: String
    let title: String
    /// What the search box becomes when it's picked.
    let search: String
}

enum RecentSearches {
    private static let key = "recentSearches"
    static var all: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count > 1 else { return }
        UserDefaults.standard.set(Array(([t] + all.filter { $0 != t }).prefix(6)), forKey: key)
    }
}

extension Store {
    /// Suggestions for what's typed so far: people, an address, the narrowing words and recent searches.
    func searchSuggestions(for typed: String) -> [SearchSuggestion] {
        let text = typed.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            return RecentSearches.all.map { SearchSuggestion(id: "recent:" + $0, icon: "clock.arrow.circlepath", title: $0, search: $0) }
        }
        // Only the last word is being typed; earlier ones (from:maya) stay as they are.
        var parts = SearchQuery.split(text)
        let last = parts.popLast() ?? ""
        let before = parts.joined(separator: " ")
        func with(_ token: String) -> String { (before.isEmpty ? "" : before + " ") + token + " " }
        guard !last.contains(":") else { return [] }
        var out: [SearchSuggestion] = []
        let lower = last.lowercased()
        func quoted(_ v: String) -> String { v.contains(" ") ? "\"\(v)\"" : v }

        // Typing an address: from or to it.
        if last.contains("@") {
            out.append(SearchSuggestion(id: "from:" + lower, icon: "person.crop.circle", title: String(localized: "From \(last)"), search: with("from:" + last)))
            out.append(SearchSuggestion(id: "to:" + lower, icon: "paperplane", title: String(localized: "To \(last)"), search: with("to:" + last)))
        }
        // People in your contacts and inbox whose name or address starts with what's typed.
        if last.count >= 2 {
            var seen = Set<String>()
            let people = accounts.flatMap(\.contacts).filter { c in
                c.email.lowercased().hasPrefix(lower) ||
                c.name.lowercased().split(separator: " ").contains { $0.hasPrefix(lower) }
            }
            for c in people where seen.insert(c.id).inserted {
                let name = c.name.isEmpty ? c.email : c.name
                out.append(SearchSuggestion(id: "from:" + c.id, icon: "person.crop.circle", title: String(localized: "From \(name)"), search: with("from:" + c.email)))
                out.append(SearchSuggestion(id: "to:" + c.id, icon: "paperplane", title: String(localized: "To \(name)"), search: with("to:" + c.email)))
                if seen.count >= 3 { break }
            }
            out.append(SearchSuggestion(id: "subject:" + lower, icon: "textformat", title: String(localized: "Subject contains \"\(last)\""), search: with("subject:" + quoted(last))))
        }
        // The narrowing words, offered once.
        let query = SearchQuery(text)
        if !query.hasAttachment { out.append(SearchSuggestion(id: "has:attachment", icon: "paperclip", title: "With attachments", search: text + " has:attachment ")) }
        if !query.unread { out.append(SearchSuggestion(id: "is:unread", icon: "envelope.badge", title: "Unread only", search: text + " is:unread ")) }
        if !query.starred { out.append(SearchSuggestion(id: "is:starred", icon: "star", title: "Starred only", search: text + " is:starred ")) }
        return out
    }

    /// Loads contacts for suggestions the first time search is used.
    func prepareSearchSuggestions() async {
        for s in accounts { await s.loadContacts() }
    }
}

/// The suggestions list under the Mac search box.
struct SearchSuggestionsList: View {
    @EnvironmentObject var store: Store
    let pick: (SearchSuggestion) -> Void

    var body: some View {
        let items = store.searchSuggestions(for: store.search)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items.prefix(8)) { s in
                    Button { pick(s) } label: {
                        Label(s.title, systemImage: s.icon)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                }
            }
            .padding(.bottom, 6)
        }
    }
}
