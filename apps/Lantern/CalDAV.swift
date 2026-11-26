// Talking to a calendar server over CalDAV (RFC 4791), with scheduling (RFC 6638) for answering invitations.
//
// Fastmail: calendars aren't open over JMAP yet, so the app uses https://caldav.fastmail.com with a token from the
// same Sign in with Fastmail (see FastmailOAuth.calendarHeader). Stalwart and others: the same email and app password
// as mail, on the server's own /.well-known/caldav.

import Foundation

/// A calendar on the server.
struct CalendarInfo: Codable, Hashable, Identifiable {
    let accountId: String
    let href: String
    var name: String
    var colour: String?          // #RRGGBB from the server, if it has one
    var ctag: String?            // changes whenever anything in the calendar changes
    var events: Bool             // holds events (not just tasks)
    var writable: Bool
    var id: String { accountId + "|" + href }
}

/// One file on the server: an event (with any changed times of a repeating event) as calendar text.
struct CalendarResource: Codable, Hashable {
    let href: String
    var etag: String?
    var ics: String
}

/// Where a person's calendars live on the server, found once and remembered.
struct CalendarHome: Codable, Hashable {
    var home: String
    var inbox: String?
    var outbox: String?
    /// The person's own addresses (mailto:), used to find them among an event's guests.
    var addresses: [String]
}

enum CalDAVError: LocalizedError {
    case http(Int), notFound, notInvited
    var errorDescription: String? {
        switch self {
        case .http(401), .http(403): return "The calendar server didn't accept the sign in."
        case .http(412): return "The event changed on the server. Try again."
        case .http(let c): return "The calendar server answered with an error (\(c))."
        case .notFound: return "Couldn't find your calendars on the server."
        case .notInvited: return "This invitation wasn't sent to any of your addresses."
        }
    }
}

final class CalDAVClient: @unchecked Sendable {
    let base: URL
    /// The Authorization header, refreshed first when `fresh` is true (after the server says 401).
    private let header: (_ fresh: Bool) async throws -> String
    private let http: URLSession

    init(base: URL, header: @escaping (_ fresh: Bool) async throws -> String) {
        self.base = base
        self.header = header
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        http = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    static let davNS = "DAV:"
    static let calNS = "urn:ietf:params:xml:ns:caldav"

    // MARK: Requests

    struct Reply {
        let code: Int
        let xml: DAVNode?
        let etag: String?
        let data: Data
    }

    /// Sends a request, following redirects by hand (so the method and body are kept) and signing in again once on 401.
    func send(_ method: String, _ path: String, depth: String? = nil, body: String? = nil,
              contentType: String = "application/xml; charset=utf-8", headers: [String: String] = [:]) async throws -> Reply {
        var url = URL(string: path, relativeTo: base)?.absoluteURL ?? base
        var fresh = false
        for _ in 0..<6 {
            var r = URLRequest(url: url)
            r.httpMethod = method
            r.setValue(try await header(fresh), forHTTPHeaderField: "Authorization")
            if let depth { r.setValue(depth, forHTTPHeaderField: "Depth") }
            if let body {
                r.httpBody = Data(body.utf8)
                r.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
            let (data, response) = try await http.data(for: r)
            let h = response as? HTTPURLResponse
            let code = h?.statusCode ?? 0
            if code == 401 && !fresh { fresh = true; continue }
            if (300..<400).contains(code), code != 304, let to = h?.value(forHTTPHeaderField: "Location"),
               let next = URL(string: to, relativeTo: url) {
                url = next.absoluteURL
                continue
            }
            let isXML = (h?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("xml")
            return Reply(code: code, xml: isXML || code == 207 ? DAVNode.parse(data) : nil,
                         etag: h?.value(forHTTPHeaderField: "ETag"), data: data)
        }
        throw CalDAVError.notFound
    }

    // MARK: Finding the calendars

    func discover() async throws -> CalendarHome {
        let ask = """
        <?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>
        """
        var principal: String?
        for start in ["/.well-known/caldav", base.path.isEmpty ? "/" : base.path] {
            let r = try await send("PROPFIND", start, depth: "0", body: ask)
            if r.code == 401 || r.code == 403 { throw CalDAVError.http(r.code) }
            if let p = r.xml?.first("current-user-principal")?.first("href")?.text { principal = p; break }
        }
        guard let principal else { throw CalDAVError.notFound }
        let props = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop><c:calendar-home-set/><c:schedule-inbox-URL/><c:schedule-outbox-URL/><c:calendar-user-address-set/></d:prop>
        </d:propfind>
        """
        let r = try await send("PROPFIND", principal, depth: "0", body: props)
        guard let xml = r.xml, let home = xml.first("calendar-home-set")?.first("href")?.text else { throw CalDAVError.notFound }
        let addresses = xml.first("calendar-user-address-set")?.all("href").map(\.text).filter { $0.lowercased().hasPrefix("mailto:") } ?? []
        return CalendarHome(home: home, inbox: xml.first("schedule-inbox-URL")?.first("href")?.text,
                            outbox: xml.first("schedule-outbox-URL")?.first("href")?.text, addresses: addresses)
    }

    func calendars(_ home: String, account: String) async throws -> [CalendarInfo] {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/" xmlns:a="http://apple.com/ns/ical/">
          <d:prop><d:resourcetype/><d:displayname/><c:supported-calendar-component-set/><cs:getctag/><d:sync-token/>
            <a:calendar-color/><d:current-user-privilege-set/></d:prop>
        </d:propfind>
        """
        let r = try await send("PROPFIND", home, depth: "1", body: body)
        guard r.code == 207, let xml = r.xml else { throw CalDAVError.http(r.code) }
        return xml.all("response").compactMap { item in
            guard let href = item.first("href")?.text, item.first("resourcetype")?.first("calendar") != nil else { return nil }
            let comps = item.first("supported-calendar-component-set")?.all("comp").compactMap { $0.attributes["name"] } ?? []
            let privileges = item.first("current-user-privilege-set")
            let writable = privileges == nil || privileges?.first("write") != nil || privileges?.first("write-content") != nil
                || privileges?.first("all") != nil
            var colour = item.first("calendar-color")?.text
            if let c = colour, c.count == 9 { colour = String(c.prefix(7)) }   // #RRGGBBAA
            return CalendarInfo(accountId: account, href: href,
                                name: item.first("displayname")?.text.nilIfEmpty ?? "Calendar",
                                colour: colour,
                                ctag: item.first("getctag")?.text.nilIfEmpty ?? item.first("sync-token")?.text.nilIfEmpty,
                                events: comps.isEmpty || comps.contains("VEVENT"), writable: writable)
        }
    }

    // MARK: Events

    /// Every event that happens (or has a repeat that happens) between two moments.
    func events(_ calendar: String, from: Date, to: Date) async throws -> [CalendarResource] {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop><d:getetag/><c:calendar-data/></d:prop>
          <c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">
            <c:time-range start="\(ICal.stamp(from))" end="\(ICal.stamp(to))"/>
          </c:comp-filter></c:comp-filter></c:filter>
        </c:calendar-query>
        """
        return try await query(calendar, body)
    }

    /// The event with this UID in a calendar, if it's there.
    func event(uid: String, in calendar: String) async throws -> CalendarResource? {
        let safe = uid.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop><d:getetag/><c:calendar-data/></d:prop>
          <c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">
            <c:prop-filter name="UID"><c:text-match collation="i;octet">\(safe)</c:text-match></c:prop-filter>
          </c:comp-filter></c:comp-filter></c:filter>
        </c:calendar-query>
        """
        return try await query(calendar, body).first
    }

    private func query(_ calendar: String, _ body: String) async throws -> [CalendarResource] {
        let r = try await send("REPORT", calendar, depth: "1", body: body)
        guard r.code == 207, let xml = r.xml else { throw CalDAVError.http(r.code) }
        return xml.all("response").compactMap { item in
            guard let href = item.first("href")?.text, let data = item.first("calendar-data")?.text, !data.isEmpty else { return nil }
            return CalendarResource(href: href, etag: item.first("getetag")?.text, ics: data)
        }
    }

    /// Saves an event. With an etag it only replaces the copy we read (412 if it changed since); without, it only
    /// creates a new one. Returns the new etag when the server gives it.
    @discardableResult
    func put(_ href: String, ics: String, etag: String?) async throws -> String? {
        var headers: [String: String] = [:]
        if let etag { headers["If-Match"] = etag } else { headers["If-None-Match"] = "*" }
        let r = try await send("PUT", href, body: ics, contentType: "text/calendar; charset=utf-8", headers: headers)
        guard (200..<300).contains(r.code) else { throw CalDAVError.http(r.code) }
        return r.etag
    }

    /// Deletes an event, only if it hasn't changed since we read it.
    func delete(_ href: String, etag: String?) async throws {
        var headers: [String: String] = [:]
        if let etag { headers["If-Match"] = etag }
        let r = try await send("DELETE", href, headers: headers)
        guard (200..<300).contains(r.code) || r.code == 404 else { throw CalDAVError.http(r.code) }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// A small XML tree, matched by local name (servers use different prefixes for the same namespace).
final class DAVNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [DAVNode] = []
    init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }

    func first(_ local: String) -> DAVNode? {
        for c in children {
            if c.name == local { return c }
            if let f = c.first(local) { return f }
        }
        return nil
    }

    func all(_ local: String) -> [DAVNode] {
        children.flatMap { ($0.name == local ? [$0] : []) + $0.all(local) }
    }

    static func parse(_ data: Data) -> DAVNode? {
        let p = XMLParser(data: data)
        let b = Builder()
        p.shouldProcessNamespaces = true
        p.delegate = b
        return p.parse() ? b.root : nil
    }

    private final class Builder: NSObject, XMLParserDelegate {
        let root = DAVNode("#root", [:])
        var stack: [DAVNode] = []
        override init() { super.init(); stack = [root] }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let n = DAVNode(elementName, attributeDict)
            stack.last?.children.append(n)
            stack.append(n)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            // Calendar data keeps its line breaks; everything else is trimmed when read.
            stack.last?.text += string
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if let last = stack.last, last.name != "calendar-data" {
                last.text = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            stack.removeLast()
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
