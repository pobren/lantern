// Basic formatting in new emails (Paul, 20 Nov 2026: "B, U etc"). The buttons above the message wrap what you've
// selected in simple marks, and the email goes out as formatted HTML with a plain text copy for mail apps that
// want one:
//   **bold**   *italic*   __underline__   [link text](https://…)
//   - bullet list lines    1. numbered list lines

import Foundation

enum Formatting {
    /// Whether the text uses any of the marks (otherwise the email stays plain text, as before).
    static func used(in text: String) -> Bool {
        let patterns = [#"\*\*[^*\n]+\*\*"#, #"(?<![*\w])\*[^*\n]+\*(?![*\w])"#, #"__[^_\n]+__"#, #"\[[^\]\n]+\]\([^)\s]+\)"#,
                        #"(?m)^\s*[-•] \S"#, #"(?m)^\s*\d+[.)] \S"#]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// The email as HTML.
    static func html(_ text: String) -> String {
        var out: [String] = []
        var list: String?   // "ul" or "ol" while inside a list
        func close() { if let l = list { out.append("</\(l)>"); list = nil } }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let item = strip(line, #"^[-•] "#) {
                if list != "ul" { close(); out.append("<ul>"); list = "ul" }
                out.append("<li>\(inline(item))</li>")
            } else if let item = strip(line, #"^\d+[.)] "#) {
                if list != "ol" { close(); out.append("<ol>"); list = "ol" }
                out.append("<li>\(inline(item))</li>")
            } else {
                close()
                out.append(raw.isEmpty ? "<br>" : "<div dir=\"auto\">\(inline(raw))</div>")
            }
        }
        close()
        return "<!DOCTYPE html><html><body dir=\"auto\" style=\"font-family: -apple-system, Helvetica, Arial, sans-serif; font-size: 14px;\">"
            + out.joined(separator: "\n") + "</body></html>"
    }

    /// The plain text copy: the marks taken out, links written as "text (address)".
    static func plain(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: #"\[([^\]\n]+)\]\(([^)\s]+)\)"#, with: "$1 ($2)", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\*\*([^*\n]+)\*\*"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"__([^_\n]+)__"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<![*\w])\*([^*\n]+)\*(?![*\w])"#, with: "$1", options: .regularExpression)
        return t
    }

    private static func strip(_ line: String, _ pattern: String) -> String? {
        guard let r = line.range(of: pattern, options: .regularExpression) else { return nil }
        return String(line[r.upperBound...])
    }

    /// Bold, italic, underline and links within one line, after making the text safe for HTML.
    private static func inline(_ text: String) -> String {
        var t = JMAPClient.escape(text)
        t = t.replacingOccurrences(of: #"\[([^\]\n]+)\]\((https?://[^)\s"]+|mailto:[^)\s"]+)\)"#, with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\*\*([^*\n]+)\*\*"#, with: "<b>$1</b>", options: .regularExpression)
        t = t.replacingOccurrences(of: #"__([^_\n]+)__"#, with: "<u>$1</u>", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<![*\w])\*([^*\n]+)\*(?![*\w])"#, with: "<i>$1</i>", options: .regularExpression)
        return t
    }
}
