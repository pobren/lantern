// Share, Print and "found in this email" (Paul, 20 Nov 2026: "apple share options? share to notes, print etc" and
// "recognise dates and times and add to calendar").
//
// - Share: the standard Apple share sheet with the email as text (Notes, Messages, Reminders, AirDrop, Mail).
// - Print: the email as its sender laid it out, with From, To, Date and Subject on top (Cmd+P on the Mac).
// - Dates, times, addresses and phone numbers: on iPhone and iPad they're underlined in the email itself and a tap
//   offers Add to Calendar, Maps or Call, as in Apple Mail. The Mac's web view can't do that, so a row above the
//   email lists what was found: a date opens Calendar ready to add it, an address opens Maps, a number calls.

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum EmailText {
    /// The email's words without its HTML, for sharing and for finding dates.
    static func plain(_ html: String) -> String {
        var t = html
        t = t.replacingOccurrences(of: #"(?is)<(style|script|head)[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</div>|</li>|</tr>|</h\d>"#, with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&ldquo;", "“"), ("&rdquo;", "”"), ("&pound;", "£")] {
            t = t.replacingOccurrences(of: entity, with: char)
        }
        t = t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What goes to the share sheet: who, when, subject, then the words.
    static func forSharing(_ e: Email, html: String?) -> String {
        var lines = ["From: \(e.sender.display) <\(e.sender.email)>", "Date: \(When.long(e.date))", "Subject: \(e.title)", ""]
        lines.append(html.map(plain) ?? (e.preview ?? ""))
        return lines.joined(separator: "\n")
    }

    /// The email for printing: a small header, then the email itself. Pictures from the web are left out unless allowed.
    static func forPrinting(_ e: Email, html: String, remoteImages: Bool) -> String {
        func esc(_ s: String) -> String { JMAPClient.escape(s) }
        var body = html
        if !remoteImages {
            body = body.replacingOccurrences(of: #"(?i)<img[^>]+src=["']?https?:[^>]*>"#, with: "", options: .regularExpression)
        }
        let to = (e.to ?? []).map { $0.display }.joined(separator: ", ")
        let header = """
        <div style="font-family: -apple-system, Helvetica, Arial, sans-serif; font-size: 12px; color: #333; border-bottom: 1px solid #ccc; padding-bottom: 8px; margin-bottom: 12px;">
        <div style="font-size: 16px; font-weight: 600; margin-bottom: 6px;">\(esc(e.title))</div>
        <div><b>From:</b> \(esc(e.sender.display)) &lt;\(esc(e.sender.email))&gt;</div>
        \(to.isEmpty ? "" : "<div><b>To:</b> \(esc(to))</div>")
        <div><b>Date:</b> \(esc(When.long(e.date)))</div>
        </div>
        """
        return "<html><body>" + header + body + "</body></html>"
    }
}

enum EmailPrinter {
    @MainActor
    static func print(_ e: Email, html: String, remoteImages: Bool) {
        let page = EmailText.forPrinting(e, html: html, remoteImages: remoteImages)
        #if os(macOS)
        guard let text = try? NSAttributedString(data: Data(page.utf8),
                                                 options: [.documentType: NSAttributedString.DocumentType.html,
                                                           .characterEncoding: String.Encoding.utf8.rawValue],
                                                 documentAttributes: nil) else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.textStorage?.setAttributedString(text)
        view.isVerticallyResizable = true
        view.sizeToFit()
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = e.title
        op.run()
        #else
        let controller = UIPrintInteractionController.shared
        let job = UIPrintInfo(dictionary: nil)
        job.outputType = .general
        job.jobName = e.title
        controller.printInfo = job
        controller.printFormatter = UIMarkupTextPrintFormatter(markupText: page)
        controller.present(animated: true)
        #endif
    }
}

/// Something worth acting on in an email: a date and time, an address or a phone number.
struct FoundItem: Identifiable, Hashable {
    enum Kind: Hashable { case date(Date, Date?, allDay: Bool), address(String), phone(String) }
    let id: String
    let kind: Kind
    let text: String

    static func find(in text: String) -> [FoundItem] {
        let types: NSTextCheckingResult.CheckingType = [.date, .address, .phoneNumber]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return [] }
        let ns = text as NSString
        var out: [FoundItem] = []
        var seen = Set<String>()
        for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let words = ns.substring(with: m.range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard seen.insert(words.lowercased()).inserted else { continue }
            switch m.resultType {
            case .date:
                guard let d = m.date, d > Date().addingTimeInterval(-3600) else { continue }   // only what's still ahead
                // A bare weekday or "today" on its own isn't worth a button; a time or a real date is.
                guard words.count > 5 else { continue }
                let end = m.duration > 0 ? d.addingTimeInterval(m.duration) : nil
                let allDay = !words.contains(":") && !words.lowercased().contains("am") && !words.lowercased().contains("pm")
                out.append(FoundItem(id: "d" + words, kind: .date(d, end, allDay: allDay), text: words))
            case .address:
                out.append(FoundItem(id: "a" + words, kind: .address(words.replacingOccurrences(of: "\n", with: ", ")), text: words))
            case .phoneNumber:
                guard let n = m.phoneNumber, n.filter(\.isNumber).count >= 7 else { continue }
                out.append(FoundItem(id: "p" + n, kind: .phone(n), text: n))
            default: continue
            }
            if out.count >= 5 { break }
        }
        return out
    }
}

/// The row of things found above the email (Mac; iPhone and iPad underline them in the email instead).
struct FoundInEmail: View {
    let items: [FoundItem]
    let subject: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    Button { act(item) } label: {
                        Label(label(item), systemImage: icon(item)).lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(help(item))
                }
            }
        }
    }

    private func label(_ i: FoundItem) -> String {
        switch i.kind {
        case .date(let d, _, let allDay):
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_GB")
            f.dateFormat = allDay ? "EEE d MMM" : "EEE d MMM, HH:mm"
            return String(localized: "Add \(f.string(from: d)) to Calendar")
        case .address(let a): return a
        case .phone(let n): return n
        }
    }

    private func icon(_ i: FoundItem) -> String {
        switch i.kind {
        case .date: return "calendar.badge.plus"
        case .address: return "map"
        case .phone: return "phone"
        }
    }

    private func help(_ i: FoundItem) -> String {
        switch i.kind {
        case .date: return String(localized: "Opens Calendar with \"\(subject)\" ready to add")
        case .address: return "Open in Maps"
        case .phone: return "Call"
        }
    }

    private func act(_ i: FoundItem) {
        switch i.kind {
        case .date(let start, let end, let allDay):
            CalendarFile.open(title: subject, start: start, end: end, allDay: allDay)
        case .address(let a):
            var c = URLComponents(string: "https://maps.apple.com/")!
            c.queryItems = [URLQueryItem(name: "q", value: a)]
            if let url = c.url { openLink(url) }
        case .phone(let n):
            if let url = URL(string: "tel:" + n.filter { "+0123456789".contains($0) }) { openLink(url) }
        }
    }

    private func openLink(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

/// A one-event calendar file: opening it asks Calendar to add the event, with no access to your calendars needed.
enum CalendarFile {
    static func open(title: String, start: Date, end: Date?, allDay: Bool) {
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyyMMdd"
        let safe = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: "\n", with: " ")
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//JMAP Connect//EN", "BEGIN:VEVENT",
                     "UID:\(UUID().uuidString)@jmapconnect.app", "DTSTAMP:\(utc.string(from: Date()))", "SUMMARY:\(safe)"]
        if allDay {
            lines.append("DTSTART;VALUE=DATE:\(day.string(from: start))")
            lines.append("DTEND;VALUE=DATE:\(day.string(from: start.addingTimeInterval(86_400)))")
        } else {
            lines.append("DTSTART:\(utc.string(from: start))")
            lines.append("DTEND:\(utc.string(from: end ?? start.addingTimeInterval(3600)))")
        }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Event.ics")
        try? lines.joined(separator: "\r\n").data(using: .utf8)?.write(to: url)
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }
}
