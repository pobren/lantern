// TEST BUILD ONLY (Paul, 26 Nov 2026): can JMAP Connect reach Fastmail calendars? Remove before any App Store release.
//
// Fastmail's sign in settings now list a calendars permission (urn:ietf:params:oauth:scope:calendars) and the
// calendar server https://caldav.fastmail.com as something a sign in can be for. Calendars aren't open over JMAP
// yet, so a calendar in the app would talk CalDAV. This checks, on a real account, before we build anything:
//   1. Fastmail accepts a sign in asking for mail, contacts and calendars.
//   2. The same sign in gives a token for the calendar server (a refresh naming that server, RFC 8707).
//   3. That token lists the calendars and finds this week's events.
//   4. The calendar server offers scheduling (the inbox and outbox used to answer invitations).
// It's a separate sign in that's revoked at the end, so the accounts in the app are never touched. Results show
// counts and calendar names only, never event details, so they can be copied into a chat.

import SwiftUI
import AuthenticationServices
import Security
import CryptoKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct CalendarTestSection: View {
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var lines: [String] = []
    @State private var running = false

    var body: some View {
        Section {
            Button { start() } label: {
                Label(running ? "Testing calendar access" : "Test calendar access", systemImage: "calendar.badge.checkmark")
            }
            .disabled(running)
            if !lines.isEmpty {
                Text(lines.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button { copy() } label: { Label("Copy results", systemImage: "doc.on.doc") }
                    .disabled(running)
            }
        } header: {
            Text("Calendar test")
        } footer: {
            Text("Test build only. Signs in to Fastmail once more asking for calendar access, lists your calendars and counts this week's events, then ends that sign in. Your accounts here aren't changed.")
        }
    }

    private func copy() {
        let text = lines.joined(separator: "\n")
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private func start() {
        Task {
            running = true
            lines = []
            defer { running = false }
            let test = CalendarTest { line in lines.append(line) }
            await test.run(webAuth)
        }
    }
}

@MainActor
private struct CalendarTest {
    let say: (String) -> Void

    static let caldav = "https://caldav.fastmail.com"
    static let scopes = ["urn:ietf:params:oauth:scope:mail", "urn:ietf:params:oauth:scope:contacts",
                         "urn:ietf:params:oauth:scope:calendars", "offline_access"]

    func run(_ webAuth: WebAuthenticationSession) async {
        let info = Bundle.main.infoDictionary
        say("JMAP Connect \(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? "")), \(Date().formatted(date: .abbreviated, time: .shortened))")

        // 1. Sign in asking for calendars too.
        let verifier = Self.random(48)
        let challenge = Data(SHA256Digest.of(verifier)).base64URL
        let state = Self.random(24)
        var c = URLComponents(url: FastmailOAuth.authorize, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "client_id", value: FastmailOAuth.clientId),
            .init(name: "redirect_uri", value: FastmailOAuth.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "resource", value: FastmailOAuth.resource),
        ]
        let back: URL
        do {
            back = try await webAuth.authenticate(using: c.url!, callbackURLScheme: FastmailOAuth.callbackScheme,
                                                  preferredBrowserSession: .ephemeral)
        } catch {
            say("1 Sign in: FAILED, the sign in window closed (\(error.localizedDescription))")
            return
        }
        let items = URLComponents(url: back, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == state else { say("1 Sign in: FAILED, the reply didn't match"); return }
        if let e = value("error") { say("1 Sign in: REFUSED by Fastmail: \(e) \(value("error_description") ?? "")"); return }
        guard let code = value("code") else { say("1 Sign in: FAILED, no code came back"); return }

        var token: Tokens
        do {
            token = try await Self.post(["client_id": FastmailOAuth.clientId, "redirect_uri": FastmailOAuth.redirectURI,
                                         "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
                                         "resource": FastmailOAuth.resource])
        } catch {
            say("1 Sign in: FAILED at the token swap: \(error)")
            return
        }
        let hasCalendars = token.scope.split(separator: " ").contains { $0 == "urn:ietf:params:oauth:scope:calendars" }
        say("1 Sign in: OK. Fastmail granted: \(token.scope.isEmpty ? "(not stated)" : token.scope)")
        say(hasCalendars || token.scope.isEmpty ? "  Calendars permission: granted" : "  Calendars permission: NOT granted")
        await afterSignIn(&token)
        await Self.revoke(token.refresh)
        say("Test sign in ended (revoked).")
    }

    /// Steps 2 to 4, once signed in. Keeps the newest refresh token in `token` so it can be revoked after.
    func afterSignIn(_ token: inout Tokens) async {
        // The mail token still works as before (so one sign in can serve mail and calendar).
        do {
            var r = URLRequest(url: URL(string: FastmailOAuth.sessionURL)!)
            r.setValue("Bearer \(token.access)", forHTTPHeaderField: "Authorization")
            let (_, resp) = try await URLSession.shared.data(for: r)
            say("  Mail (JMAP) with this sign in: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        } catch { say("  Mail (JMAP) with this sign in: \(error.localizedDescription)") }

        // 2. A token for the calendar server from the same sign in.
        var calendarToken: String?
        do {
            let fresh = try await Self.post(["client_id": FastmailOAuth.clientId, "grant_type": "refresh_token",
                                             "refresh_token": token.refresh, "resource": Self.caldav])
            token.refresh = fresh.refresh
            calendarToken = fresh.access
            say("2 Calendar token: OK (granted \(fresh.scope.isEmpty ? "scope not stated" : fresh.scope))")
        } catch {
            say("2 Calendar token: FAILED: \(error)")
            say("  Trying the mail token on the calendar server instead")
            calendarToken = token.access
        }
        guard let bearer = calendarToken else { return }

        // 3. Find the calendars.
        let dav = DAV(bearer: bearer, say: say)
        guard let principal = await dav.principal() else { return }
        say("3 Calendar server: signed in")
        let home = await dav.property(principal, "calendar-home-set", ns: "urn:ietf:params:xml:ns:caldav")
        let inbox = await dav.property(principal, "schedule-inbox-URL", ns: "urn:ietf:params:xml:ns:caldav")
        let outbox = await dav.property(principal, "schedule-outbox-URL", ns: "urn:ietf:params:xml:ns:caldav")
        guard let home else { say("  Calendar home: NOT FOUND"); return }
        let calendars = await dav.calendars(home)
        say("  Calendars found: \(calendars.count)")
        for cal in calendars { say("   · \(cal.name)\(cal.events ? "" : " (no events, tasks only)")") }

        // This week, Monday to Sunday.
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let weekEnd = weekStart.addingTimeInterval(7 * 86_400)
        var total = 0
        var failed = 0
        for c in calendars where c.events {
            if let n = await dav.countEvents(c.href, from: weekStart, to: weekEnd) { total += n } else { failed += 1 }
        }
        say("  Events this week: \(total)\(failed > 0 ? " (\(failed) calendars couldn't be read)" : "")")

        // 4. Invitations: the scheduling inbox and outbox.
        say("4 Invitations (scheduling): \(inbox != nil && outbox != nil ? "OK, inbox and outbox offered" : "NOT offered")")
        say(calendars.isEmpty ? "RESULT: calendar access did not work" : "RESULT: calendar access works")
    }

    // MARK: Token endpoint

    struct Tokens { var access: String; var refresh: String; var scope: String }

    struct Refused: Error, CustomStringConvertible {
        let code: Int; let error: String
        var description: String { "HTTP \(code) \(error)" }
    }

    static func post(_ fields: [String: String]) async throws -> Tokens {
        var r = URLRequest(url: FastmailOAuth.tokenURL)
        r.httpMethod = "POST"
        r.timeoutInterval = 30
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = form(fields)
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard code == 200, let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            let e = [json["error"] as? String, json["error_description"] as? String].compactMap { $0 }.joined(separator: ": ")
            throw Refused(code: code, error: e.isEmpty ? String(decoding: data.prefix(200), as: UTF8.self) : e)
        }
        return Tokens(access: access, refresh: refresh, scope: json["scope"] as? String ?? "")
    }

    static func revoke(_ refresh: String) async {
        var r = URLRequest(url: FastmailOAuth.revokeURL)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = form(["client_id": FastmailOAuth.clientId, "token": refresh, "token_type_hint": "refresh_token"])
        _ = try? await URLSession.shared.data(for: r)
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").utf8)
    }

    static func random(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Data(b).base64URL
    }
}

private enum SHA256Digest {
    static func of(_ s: String) -> [UInt8] { Array(SHA256.hash(data: Data(s.utf8))) }
}

// MARK: A very small CalDAV client, enough for the test

@MainActor
private struct DAV {
    let bearer: String
    let say: (String) -> Void
    static let base = URL(string: "https://caldav.fastmail.com")!

    struct CalendarInfo { let href: String; let name: String; let events: Bool }

    /// Sends a WebDAV request, following redirects by hand so the method and body are kept.
    func send(_ method: String, _ path: String, depth: String, body: String) async -> (Int, XMLNode?) {
        var url = URL(string: path, relativeTo: Self.base)!.absoluteURL
        for _ in 0..<5 {
            var r = URLRequest(url: url)
            r.httpMethod = method
            r.timeoutInterval = 30
            r.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            r.setValue(depth, forHTTPHeaderField: "Depth")
            r.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data(body.utf8)
            do {
                let (data, response) = try await URLSession.shared.data(for: r, delegate: NoRedirects())
                let http = response as? HTTPURLResponse
                let code = http?.statusCode ?? 0
                if (300..<400).contains(code), let to = http?.value(forHTTPHeaderField: "Location"),
                   let next = URL(string: to, relativeTo: url) {
                    url = next.absoluteURL
                    continue
                }
                return (code, XMLNode.parse(data))
            } catch {
                say("  \(method) failed: \(error.localizedDescription)")
                return (0, nil)
            }
        }
        return (0, nil)
    }

    func principal() async -> String? {
        let body = """
        <?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>
        """
        for start in ["/.well-known/caldav", "/"] {
            let (code, xml) = await send("PROPFIND", start, depth: "0", body: body)
            if code == 401 || code == 403 { say("3 Calendar server: REFUSED the token (HTTP \(code))"); return nil }
            if let href = xml?.first("current-user-principal")?.first("href")?.text { return href }
            say("  \(start): HTTP \(code), no principal")
        }
        say("3 Calendar server: couldn't find your calendar account")
        return nil
    }

    func property(_ href: String, _ name: String, ns: String) async -> String? {
        let body = """
        <?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:c="\(ns)"><d:prop><c:\(name)/></d:prop></d:propfind>
        """
        let (_, xml) = await send("PROPFIND", href, depth: "0", body: body)
        return xml?.first(name)?.first("href")?.text
    }

    func calendars(_ home: String) async -> [CalendarInfo] {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop><d:resourcetype/><d:displayname/><c:supported-calendar-component-set/></d:prop>
        </d:propfind>
        """
        let (code, xml) = await send("PROPFIND", home, depth: "1", body: body)
        guard let xml else { say("  Calendar list: HTTP \(code)"); return [] }
        return xml.all("response").compactMap { r in
            guard let href = r.first("href")?.text, r.first("resourcetype")?.first("calendar") != nil else { return nil }
            let name = r.first("displayname")?.text ?? "(no name)"
            let comps = r.first("supported-calendar-component-set")?.all("comp").compactMap { $0.attributes["name"] } ?? []
            return CalendarInfo(href: href, name: name, events: comps.isEmpty || comps.contains("VEVENT"))
        }
    }

    func countEvents(_ href: String, from: Date, to: Date) async -> Int? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop><d:getetag/></d:prop>
          <c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">
            <c:time-range start="\(f.string(from: from))" end="\(f.string(from: to))"/>
          </c:comp-filter></c:comp-filter></c:filter>
        </c:calendar-query>
        """
        let (code, xml) = await send("REPORT", href, depth: "1", body: body)
        guard code == 207, let xml else { return nil }
        return xml.all("response").count
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// A tiny XML tree, matched by local name (namespace prefixes differ between servers).
private final class XMLNode {
    let name: String
    var attributes: [String: String]
    var text = ""
    var children: [XMLNode] = []
    init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }

    func first(_ local: String) -> XMLNode? {
        for c in children {
            if c.name == local { return c }
            if let f = c.first(local) { return f }
        }
        return nil
    }

    func all(_ local: String) -> [XMLNode] {
        children.flatMap { ($0.name == local ? [$0] : []) + $0.all(local) }
    }

    static func parse(_ data: Data) -> XMLNode? {
        let p = XMLParser(data: data)
        let b = Builder()
        p.shouldProcessNamespaces = true
        p.delegate = b
        return p.parse() ? b.root : nil
    }

    private final class Builder: NSObject, XMLParserDelegate {
        let root = XMLNode("#root", [:])
        var stack: [XMLNode] = []
        override init() { super.init(); stack = [root] }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let n = XMLNode(elementName, attributeDict)
            stack.last?.children.append(n)
            stack.append(n)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            stack.removeLast()
        }
    }
}
