// Tracker blocking (Paul, 21 Nov 2026). Many emails carry a hidden picture, usually one pixel, that tells the sender
// when and where you opened it. The app takes those out before the email is shown, so nothing is fetched even when
// pictures from the web are allowed, and says how many it blocked. All done in the app: no server sees your email.

import SwiftUI

enum Trackers {
    static let key = "blockTrackers"
    static var on: Bool { UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key) }

    /// Mail services whose pictures are only ever there to track opens.
    private static let hosts = [
        "list-manage.com/track", "mailchimp.com/track", "sendgrid.net/wf/open", "ct.sendgrid.net", "mandrillapp.com/track",
        "mailgun.org/o/", "hubspotemail.net", "hs-email.com", "t.hubspot", "track.hubspot", "sparkpostmail.com/q/",
        "spgo.io", "klaviyo.com/open", "trk.klclick", "convertkit-mail", "email.mg.", "emltrk.com", "mailtrack.io",
        "getnotify.com", "bananatag", "yesware.com", "mixmax.com", "streak.com", "superhuman.com", "pixel.wp.com",
        "google-analytics.com/collect", "doubleclick.net", "mktotracking", "mkt.", "exacttarget.com/open",
        "cmail19.com/t/", "cmail20.com/t/", "createsend", "awstrack.me", "r.mail", "/e/o/", "beehiiv.com/open",
        "substack.com/o/", "mailerlite.com/open", "sendinblue.com/tr/", "brevo.com/tr/", "postmarkapp.com/open",
        "aweber.com", "constantcontact.com/open", "rs6.net/on.jsp", "tinyletter", "campaign-archive",
    ]

    /// Path shapes used for open tracking.
    private static let paths = #"(?i)(/open(\.gif|\.png|\.aspx|\?|/)|/track/open|/wf/open|/pixel(\.gif|\.png|/|\?)|/beacon|/trk\?|/openrate|/o\.gif|[?&](utm_medium=email&)?.*open_tracking)"#

    /// The email with its trackers taken out, and how many there were.
    static func clean(_ html: String) -> (html: String, blocked: Int) {
        guard on, html.range(of: "<img", options: .caseInsensitive) != nil else { return (html, 0) }
        guard let regex = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive]) else { return (html, 0) }
        let ns = html as NSString
        var out = ""
        var last = 0
        var blocked = 0
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if isTracker(tag) { blocked += 1 } else { out += tag }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return (out, blocked)
    }

    static func isTracker(_ tag: String) -> Bool {
        let lower = tag.lowercased()
        guard let src = attribute("src", in: tag)?.lowercased(), src.hasPrefix("http") else { return false }
        // One or no pixels across, or hidden: a picture you can't see is there for a reason.
        let w = attribute("width", in: tag).flatMap { Int($0.filter(\.isNumber)) }
        let h = attribute("height", in: tag).flatMap { Int($0.filter(\.isNumber)) }
        if let w, let h, w <= 2, h <= 2 { return true }
        if lower.range(of: #"(width|height)\s*:\s*[01]px"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"display\s*:\s*none|visibility\s*:\s*hidden"#, options: .regularExpression) != nil { return true }
        if hosts.contains(where: { src.contains($0) }) && (w ?? 0) <= 2 || hosts.contains(where: { src.contains($0) }) && src.contains("open") { return true }
        if src.range(of: paths, options: .regularExpression) != nil && (w == nil || (w ?? 0) <= 2) { return true }
        return false
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"(?i)\b"# + name + #"\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let r = try? NSRegularExpression(pattern: pattern),
              let m = r.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        for i in [2, 3, 4] where m.range(at: i).location != NSNotFound {
            return (tag as NSString).substring(with: m.range(at: i))
        }
        return nil
    }
}

/// "Blocked 2 trackers" above the email.
struct TrackersBlocked: View {
    let count: Int
    @State private var explaining = false

    var body: some View {
        Button { explaining = true } label: {
            Label(count == 1 ? "Blocked 1 tracker" : "Blocked \(count) trackers", systemImage: "eye.trianglebadge.exclamationmark")
                .font(.callout)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Look.other)
        .help("This email had hidden pictures that tell the sender when you open it. They were removed.")
        .alert("Trackers blocked", isPresented: $explaining) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(count == 1
                 ? "This email had a hidden picture that would tell the sender when and where you opened it. JMAP Connect took it out before showing the email, so the sender doesn't know. You can turn this off in Settings."
                 : "This email had \(count) hidden pictures that would tell the sender when and where you opened it. JMAP Connect took them out before showing the email, so the sender doesn't know. You can turn this off in Settings.")
        }
    }
}
