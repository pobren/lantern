// The calendar (1.3, Paul 26 Nov 2026): your calendars from Fastmail (and Stalwart), shown by day and by week, kept on
// the device so they open offline, and answering invitations from the email.
//
// What's kept: for each account, where its calendars live, the list of calendars and the calendar files for a window
// from two months back to thirteen months ahead, in Application Support/Calendar (out of backups). A calendar is
// fetched again only when its change tag (ctag) moves. Weeks outside the window are fetched when you go to them.

import Foundation
import SwiftUI
import AuthenticationServices

/// Someone on an event: the organiser or a guest.
struct CalPerson: Hashable, Identifiable {
    let name: String
    let email: String
    /// ACCEPTED, DECLINED, TENTATIVE or NEEDS-ACTION.
    let status: String
    var id: String { email.lowercased() }
    var label: String { name.isEmpty ? email : name }

    init(_ p: ICalProperty) {
        name = p.param("CN") ?? ""
        email = CalPerson.address(p.raw)
        status = (p.param("PARTSTAT") ?? "NEEDS-ACTION").uppercased()
    }
    static func address(_ raw: String) -> String {
        var a = raw.trimmingCharacters(in: .whitespaces)
        if a.lowercased().hasPrefix("mailto:") { a = String(a.dropFirst(7)) }
        return a
    }
}

/// One time an event happens (a repeating event gives one of these for each time).
struct CalEvent: Identifiable, Hashable {
    let id: String
    let calendar: CalendarInfo
    let href: String
    let uid: String
    let title: String
    let location: String
    let notes: String
    let start: Date
    let end: Date
    let allDay: Bool
    let repeats: Bool
    let organizer: CalPerson?
    let attendees: [CalPerson]
    let joinLink: URL?
    let tentative: Bool

    static func == (a: CalEvent, b: CalEvent) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// The times as people say them: "10:00 to 11:30", "All day", "Thu 26 Nov to Sat 28 Nov".
    var timeText: String {
        let cal = Foundation.Calendar.current
        if allDay {
            let last = end.addingTimeInterval(-1)
            if cal.isDate(start, inSameDayAs: last) { return "All day" }
            return "\(CalText.day.string(from: start)) to \(CalText.day.string(from: last))"
        }
        if cal.isDate(start, inSameDayAs: end) || end.timeIntervalSince(start) < 1 {
            return "\(CalText.time.string(from: start)) to \(CalText.time.string(from: end))"
        }
        return "\(CalText.dayTime.string(from: start)) to \(CalText.dayTime.string(from: end))"
    }
}

enum CalText {
    static func f(_ format: String) -> DateFormatter {
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_GB")
        d.setLocalizedDateFormatFromTemplate(format)
        return d
    }
    static let time = f("HH:mm")
    static let day = f("EEE d MMM")
    static let dayTime = f("EEE d MMM HH:mm")
    static let longDay = f("EEEE d MMMM")
    static let month = f("MMMM yyyy")
    static let weekday = f("EEE")
    static let dayNumber = f("d")
    static let hour = f("HH")
}

/// Turning a calendar file into the times its events happen.
enum CalExpand {
    static func events(_ vcal: ICalComponent, calendar: CalendarInfo, href: String, in range: DateInterval) -> [CalEvent] {
        var out: [CalEvent] = []
        let all = vcal.events
        let overrides = all.filter { $0.prop("RECURRENCE-ID") != nil }
        let moved = Set(overrides.compactMap { $0.prop("RECURRENCE-ID").flatMap { ICal.when($0)?.date } })
        for e in all {
            guard let startProp = e.prop("DTSTART"), let first = ICal.when(startProp) else { continue }
            if e.text("STATUS")?.uppercased() == "CANCELLED" { continue }
            let length: TimeInterval = {
                if let endProp = e.prop("DTEND"), let end = ICal.when(endProp) { return max(0, end.date.timeIntervalSince(first.date)) }
                if let d = e.text("DURATION").flatMap(ICal.duration) { return max(0, d) }
                return first.allDay ? 86_400 : 0
            }()
            var starts: [Date] = []
            let isOverride = e.prop("RECURRENCE-ID") != nil
            if !isOverride, let raw = e.prop("RRULE")?.raw, let rule = ICal.Rule(raw, zone: first.zone) {
                starts = ICal.starts(from: first.date, rule: rule, zone: first.zone, allDay: first.allDay, limit: range.end)
                for r in e.props("RDATE") {
                    starts += r.raw.split(separator: ",").compactMap { ICal.when(r, value: String($0))?.date }
                }
                let skipped = Set(e.props("EXDATE").flatMap { x in x.raw.split(separator: ",").compactMap { ICal.when(x, value: String($0))?.date } })
                starts = starts.filter { s in !skipped.contains(s) && !moved.contains(s) }
                if first.allDay {
                    let cal = Foundation.Calendar.current
                    let skippedDays = Set(skipped.map { cal.startOfDay(for: $0) })
                    starts = starts.filter { !skippedDays.contains(cal.startOfDay(for: $0)) }
                }
            } else {
                starts = [first.date]
            }
            for s in starts {
                // An all-day event "on" a day covers it entirely; a timed one needs to overlap.
                let end = s.addingTimeInterval(length)
                guard s < range.end, end > range.start || (length == 0 && s >= range.start) else { continue }
                out.append(make(e, calendar: calendar, href: href, start: s, end: end, allDay: first.allDay,
                                repeats: e.prop("RRULE") != nil || isOverride))
            }
        }
        return out
    }

    static func make(_ e: ICalComponent, calendar: CalendarInfo, href: String, start: Date, end: Date, allDay: Bool, repeats: Bool) -> CalEvent {
        let uid = e.text("UID") ?? href
        let location = e.text("LOCATION") ?? ""
        let notes = e.text("DESCRIPTION") ?? ""
        return CalEvent(id: "\(calendar.id)|\(href)|\(uid)|\(Int(start.timeIntervalSince1970))", calendar: calendar, href: href, uid: uid,
                        title: (e.text("SUMMARY") ?? "").nilIfEmpty ?? "(No title)", location: location, notes: notes,
                        start: start, end: end, allDay: allDay, repeats: repeats,
                        organizer: e.prop("ORGANIZER").map(CalPerson.init),
                        attendees: e.props("ATTENDEE").map(CalPerson.init),
                        joinLink: joinLink(e, location: location, notes: notes),
                        tentative: e.text("STATUS")?.uppercased() == "TENTATIVE")
    }

    /// A link to join a video call: the event's own URL, a conference link, or the first meeting link in the
    /// place or notes (Zoom, Teams, Meet, Webex, Whereby, FaceTime).
    static func joinLink(_ e: ICalComponent, location: String, notes: String) -> URL? {
        for key in ["X-GOOGLE-CONFERENCE", "X-MICROSOFT-SKYPETEAMSMEETINGURL", "CONFERENCE"] {
            if let u = e.text(key).flatMap(URL.init(string:)), u.scheme?.hasPrefix("http") == true { return u }
        }
        let hosts = ["zoom.us", "teams.microsoft.com", "teams.live.com", "meet.google.com", "webex.com", "whereby.com", "facetime.apple.com", "meet.jit.si"]
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in [location, notes, e.text("URL") ?? ""] {
            let ns = text as NSString
            for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if let u = m.url, let h = u.host?.lowercased(), hosts.contains(where: { h == $0 || h.hasSuffix("." + $0) }) { return u }
            }
        }
        return nil
    }
}

@MainActor
final class CalendarModel: ObservableObject {
    /// One for the app, so an invitation in any window (a Mac email in its own window too) can reach the calendar.
    static let shared = CalendarModel()

    enum Mode: String { case day, week, month, list }

    @Published var calendars: [CalendarInfo] = []
    @Published var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "calendarHidden") ?? []) {
        didSet { UserDefaults.standard.set(Array(hidden), forKey: "calendarHidden") }
    }
    @Published var date = Date()
    @Published var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "calendarMode") ?? "") ?? .week {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "calendarMode") }
    }
    @Published var loading = false
    /// Accounts whose calendar needs approving (Fastmail sign ins from before 1.3, or API tokens).
    @Published var needsApproval: [String] = []
    @Published var problem: String?
    /// Bumped whenever events change, so views draw again.
    @Published private(set) var version = 0

    private var homes: [String: CalendarHome] = [:]
    private var resources: [String: [CalendarResource]] = [:]   // by calendar id
    private var extra: [String: [CalendarResource]] = [:]        // weeks fetched outside the window, not kept
    private var parsed: [String: ICalComponent] = [:]            // by calendar id + href
    private var fetchedExtra: Set<String> = []
    private var window = DateInterval(start: .distantPast, duration: 0)
    private var loaded = false

    static let enabledKinds: Set<String> = ["fastmail", Demo.kind, "stalwart", "thundermail", "mailbux", "cyrus", "other"]

    /// Whether an account could have a calendar (Mail App has none).
    static func supports(_ s: AccountState) -> Bool { enabledKinds.contains(s.account.kind) && !s.account.isMailApp }

    // MARK: Signing in to the calendar server

    /// The sign in used for an account's calendar, if it has one: its own Fastmail sign in when that includes
    /// calendars, a separate one kept for the calendar (API token accounts), or the email and app password.
    static func calendarSecret(_ s: AccountState) -> String? {
        guard let secret = Keychain.read(s.id) else { return nil }
        if s.account.kind == "fastmail" {
            if FastmailOAuth.allowsCalendars(secret) { return secret }
            if let own = Keychain.read(s.id + ".calendar"), FastmailOAuth.allowsCalendars(own) { return own }
            return nil
        }
        return secret
    }

    static func client(for s: AccountState) -> CalDAVClient? {
        guard s.account.kind != Demo.kind, let secret = calendarSecret(s) else { return nil }
        if s.account.kind == "fastmail" {
            return CalDAVClient(base: URL(string: FastmailOAuth.caldav)!) { fresh in try await FastmailOAuth.calendarHeader(secret, force: fresh) }
        }
        guard let session = URL(string: s.account.sessionURL), let scheme = session.scheme, let host = session.host else { return nil }
        var c = URLComponents()
        c.scheme = scheme; c.host = host; c.port = session.port
        guard let base = c.url else { return nil }
        return CalDAVClient(base: base) { _ in JMAPAuth.header(secret) }
    }

    /// Asks Fastmail once more, this time including calendars. Someone signed in with Fastmail keeps the same sign in
    /// (it's replaced); someone using an API token gets a separate sign in just for the calendar.
    func turnOn(_ s: AccountState, using webAuth: WebAuthenticationSession, store: Store) async {
        let request = FastmailOAuth.start()
        do {
            let back = try await webAuth.authenticate(using: request.url, callbackURLScheme: FastmailOAuth.callbackScheme,
                                                      preferredBrowserSession: .ephemeral)
            let current = Keychain.read(s.id)
            if let current, FastmailOAuth.isOAuth(current) {
                _ = try await FastmailOAuth.finish(back, request: request, into: current)
            } else {
                let old = Keychain.read(s.id + ".calendar")
                let secret = try await FastmailOAuth.finish(back, request: request, into: old.flatMap { FastmailOAuth.isOAuth($0) ? $0 : nil })
                Keychain.save(s.id + ".calendar", secret)
            }
            homes[s.id] = nil
            await refresh(store, force: true)
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
        } catch FastmailOAuth.Failure.cancelled {
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Forgets an account's calendar (when the account is removed), including its separate calendar sign in.
    static func forget(accountId: String) {
        if let own = Keychain.read(accountId + ".calendar") {
            Task { await FastmailOAuth.signOut(own) }
            Keychain.delete(accountId + ".calendar")
        }
        try? FileManager.default.removeItem(at: CalendarDisk.file(accountId))
    }

    // MARK: Loading

    private static func makeWindow() -> DateInterval {
        let cal = Foundation.Calendar.current
        let month = cal.dateInterval(of: .month, for: Date())?.start ?? Date()
        let start = cal.date(byAdding: .month, value: -2, to: month) ?? month
        let end = cal.date(byAdding: .month, value: 13, to: month) ?? month
        return DateInterval(start: start, end: end)
    }

    /// Opens what's saved on the device, then checks the servers for changes.
    func start(_ store: Store) async {
        self.store = store
        if !loaded {
            loaded = true
            window = Self.makeWindow()
            for s in store.accounts where Self.supports(s) {
                if s.account.kind == Demo.kind { loadSample(s); continue }
                guard let saved = CalendarDisk.read(s.id) else { continue }
                homes[s.id] = saved.home
                for c in saved.calendars { resources[c.id] = saved.resources[c.id] ?? [] }
                calendars.removeAll { $0.accountId == s.id }
                calendars += saved.calendars
            }
            reparse()
        }
        await refresh(store)
    }

    func refresh(_ store: Store, force: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let w = Self.makeWindow()
        let moved = w != window
        window = w
        var approve: [String] = []
        var problems: [String] = []
        for s in store.accounts where Self.supports(s) && s.account.kind != Demo.kind {
            guard let client = Self.client(for: s) else {
                if s.account.kind == "fastmail" { approve.append(s.id) }
                continue
            }
            do {
                let home: CalendarHome
                if let h = homes[s.id], !force { home = h } else { home = try await client.discover(); homes[s.id] = home }
                let fresh = try await client.calendars(home.home, account: s.id)
                let old = Dictionary(uniqueKeysWithValues: calendars.filter { $0.accountId == s.id }.map { ($0.id, $0) })
                for c in fresh where c.events {
                    if !force && !moved, let o = old[c.id], o.ctag != nil, o.ctag == c.ctag, resources[c.id] != nil { continue }
                    resources[c.id] = try await client.events(c.href, from: window.start, to: window.end)
                }
                let ids = Set(fresh.map(\.id))
                for k in old.keys where !ids.contains(k) { resources[k] = nil }
                calendars.removeAll { $0.accountId == s.id }
                calendars += fresh
                CalendarDisk.write(s.id, CalendarDisk.Saved(home: home, calendars: fresh,
                                                              resources: resources.filter { k, _ in ids.contains(k) }))
            } catch CalDAVError.notFound where s.account.kind != "fastmail" {
                // This server has no calendars for us (or none we can find): nothing to show, nothing to say.
                continue
            } catch {
                if !Store.isOffline(error) { problems.append("\(s.account.label): \(error.localizedDescription)") }
            }
        }
        needsApproval = approve
        problem = problems.first
        extra = [:]
        fetchedExtra = []
        reparse()
    }

    /// Weeks outside the saved window are fetched when someone goes to them.
    func ensure(_ range: DateInterval, store: Store) async {
        guard range.start < window.start || range.end > window.end else { return }
        let key = "\(Int(range.start.timeIntervalSince1970))"
        guard !fetchedExtra.contains(key) else { return }
        fetchedExtra.insert(key)
        for s in store.accounts where Self.supports(s) && s.account.kind != Demo.kind {
            guard let client = Self.client(for: s) else { continue }
            for c in calendars where c.accountId == s.id && c.events {
                if let more = try? await client.events(c.href, from: range.start, to: range.end) {
                    var have = extra[c.id] ?? []
                    let known = Set(have.map(\.href))
                    have += more.filter { !known.contains($0.href) }
                    extra[c.id] = have
                }
            }
        }
        reparse()
    }

    private func reparse() {
        var p: [String: ICalComponent] = [:]
        for c in calendars {
            for r in (resources[c.id] ?? []) + (extra[c.id] ?? []) {
                let key = c.id + "|" + r.href
                if p[key] != nil { continue }
                if let old = parsed[key], parsedText[key] == r.ics { p[key] = old; continue }
                if let v = ICal.parse(r.ics) { p[key] = v; parsedText[key] = r.ics }
            }
        }
        parsed = p
        version += 1
    }
    private var parsedText: [String: String] = [:]

    // MARK: Reading

    var shownCalendars: [CalendarInfo] { calendars.filter { $0.events } }

    /// The calendar file an event came from.
    func component(for e: CalEvent) -> ICalComponent? { parsed[e.calendar.id + "|" + e.href] }

    func events(in range: DateInterval) -> [CalEvent] {
        var out: [CalEvent] = []
        for c in calendars where c.events && !hidden.contains(c.id) {
            for r in (resources[c.id] ?? []) + (extra[c.id] ?? []) {
                guard let v = parsed[c.id + "|" + r.href] else { continue }
                out += CalExpand.events(v, calendar: c, href: r.href, in: range)
            }
        }
        // The same event can arrive twice (saved window and an extra fetch).
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    /// The days on show: one, or the week (Monday first) holding the chosen day.
    var days: [Date] {
        var cal = Foundation.Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        cal.timeZone = .current
        let day = cal.startOfDay(for: date)
        if mode == .day { return [day] }
        // The list runs for twelve weeks from the chosen day, like Apple's list of upcoming events.
        if mode == .list { return (0..<84).compactMap { cal.date(byAdding: .day, value: $0, to: day) } }
        if mode == .month {
            // Six weeks from the Monday on or before the 1st, so every month fits the same grid.
            let first = cal.dateInterval(of: .month, for: day)?.start ?? day
            let start = cal.dateInterval(of: .weekOfYear, for: first)?.start ?? first
            return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        }
        let start = cal.dateInterval(of: .weekOfYear, for: day)?.start ?? day
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    var range: DateInterval {
        let d = days
        let end = Foundation.Calendar.current.date(byAdding: .day, value: 1, to: d.last ?? date) ?? date
        return DateInterval(start: d.first ?? date, end: end)
    }

    func move(_ steps: Int) {
        let cal = Foundation.Calendar.current
        if mode == .month || mode == .list { date = cal.date(byAdding: .month, value: steps, to: date) ?? date; return }
        date = cal.date(byAdding: .day, value: steps * (mode == .day ? 1 : 7), to: date) ?? date
    }

    func colour(_ c: CalendarInfo) -> Color {
        if let hex = c.colour, let v = UInt32(hex.dropFirst(), radix: 16), hex.count == 7 {
            return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
        }
        let palette: [Color] = [Look.accent, .orange, .green, .purple, .pink, .teal]
        let i = c.href.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 9973 } % palette.count
        return palette[i]
    }

    // MARK: Invitations

    /// Your own addresses on an account: the calendar server's list, the account's sending addresses and its name.
    func myAddresses(_ s: AccountState) -> Set<String> {
        var a = Set((homes[s.id]?.addresses ?? []).map { CalPerson.address($0).lowercased() })
        for i in s.identities where !i.email.contains("*") { a.insert(i.email.lowercased()) }
        if s.account.username.contains("@") { a.insert(s.account.username.lowercased()) }
        if s.account.kind == Demo.kind { a.insert(Demo.me.email.lowercased()) }
        return a
    }

    /// Your answer to an event, if it's in your calendar already: ACCEPTED, TENTATIVE, DECLINED or NEEDS-ACTION.
    func myAnswer(uid: String, account s: AccountState) -> String? {
        let mine = myAddresses(s)
        for c in calendars where c.accountId == s.id {
            for r in (resources[c.id] ?? []) {
                guard let v = parsed[c.id + "|" + r.href], let e = v.events.first(where: { $0.text("UID") == uid }) else { continue }
                if let me = e.props("ATTENDEE").map(CalPerson.init).first(where: { mine.contains($0.email.lowercased()) }) { return me.status }
            }
        }
        return nil
    }

    /// Answers an invitation: your reply goes into the event in your calendar (added if it isn't there yet), and the
    /// server sends the organiser your answer, as Fastmail does when you answer in its own calendar.
    func respond(_ invite: ICalComponent, status: String, account s: AccountState, store: Store) async throws {
        guard let uid = invite.events.first?.text("UID") else { throw CalDAVError.notFound }
        let mine = myAddresses(s)
        if s.account.kind == Demo.kind {
            try answerSample(uid: uid, invite: invite, status: status, mine: mine, account: s)
            return
        }
        guard let client = Self.client(for: s) else { throw CalDAVError.http(401) }
        if !calendars.contains(where: { $0.accountId == s.id }) { await start(store) }
        if homes[s.id] == nil { homes[s.id] = try await client.discover() }
        let mineNow = myAddresses(s)
        let own = calendars.filter { $0.accountId == s.id && $0.events && $0.writable }
        var found: (CalendarInfo, CalendarResource)?
        for c in own {
            if let r = try await client.event(uid: uid, in: c.href) { found = (c, r); break }
        }
        let copy: ICalComponent
        if let f = found, let v = ICal.parse(f.1.ics) { copy = v }
        else {
            guard let v = ICal.parse(ICal.serialize(invite)) else { throw CalDAVError.notFound }
            v.properties.removeAll { $0.name == "METHOD" }
            copy = v
        }
        guard Self.setAnswer(copy, status: status, mine: mineNow) else { throw CalDAVError.notInvited }
        let text = ICal.serialize(copy)
        if let f = found {
            let c = f.0, r = f.1
            try await client.put(r.href, ics: text, etag: r.etag)
            resources[c.id] = try await client.events(c.href, from: window.start, to: window.end)
        } else {
            guard let c = own.first(where: { $0.name.lowercased() == "calendar" || $0.name.lowercased() == "main" }) ?? own.first else {
                throw CalDAVError.notFound
            }
            let name = (uid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString) + ".ics"
            let folder = c.href.hasSuffix("/") ? c.href : c.href + "/"
            try await client.put(folder + name, ics: text, etag: nil)
            resources[c.id] = try await client.events(c.href, from: window.start, to: window.end)
        }
        if let home = homes[s.id] {
            let mineCals = calendars.filter { $0.accountId == s.id }
            CalendarDisk.write(s.id, CalendarDisk.Saved(home: home, calendars: mineCals,
                                                          resources: resources.filter { k, _ in mineCals.contains { $0.id == k } }))
        }
        reparse()
    }

    /// Sets PARTSTAT on your own guest line in every part of the event. False if you aren't a guest.
    static func setAnswer(_ v: ICalComponent, status: String, mine: Set<String>) -> Bool {
        var changed = false
        for e in v.events {
            for i in e.properties.indices where e.properties[i].name == "ATTENDEE" {
                if mine.contains(CalPerson.address(e.properties[i].raw).lowercased()) {
                    e.properties[i].setParam("PARTSTAT", status)
                    e.properties[i].rawParams.removeAll { $0.0.uppercased() == "RSVP" }
                    changed = true
                }
            }
        }
        return changed
    }

    // MARK: Making, changing and deleting events

    struct Draft {
        var title = ""
        var location = ""
        var notes = ""
        var allDay = false
        var start = Date()
        var end = Date().addingTimeInterval(3_600)
        var calendarId = ""
        /// The event being changed, or nil for a new one.
        var editing: CalEvent?
    }

    var writableCalendars: [CalendarInfo] { calendars.filter { $0.events && $0.writable } }

    /// A new event on the day on show: the next hour if it's today, otherwise 9am, for an hour.
    func newDraft() -> Draft {
        let cal = Foundation.Calendar.current
        var d = Draft()
        let day = cal.startOfDay(for: date)
        let hour = cal.isDateInToday(day) ? min(23, cal.component(.hour, from: Date()) + 1) : 9
        d.start = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? date
        d.end = d.start.addingTimeInterval(3_600)
        let last = UserDefaults.standard.string(forKey: "calendarLastUsed")
        d.calendarId = writableCalendars.first { $0.id == last }?.id ?? writableCalendars.first { !hidden.contains($0.id) }?.id
            ?? writableCalendars.first?.id ?? ""
        return d
    }

    func draft(editing e: CalEvent) -> Draft {
        var d = Draft()
        d.title = e.title == "(No title)" ? "" : e.title
        d.location = e.location
        d.notes = e.notes
        d.allDay = e.allDay
        d.start = e.start
        d.end = e.allDay ? e.end.addingTimeInterval(-86_400) : e.end
        d.calendarId = e.calendar.id
        d.editing = e
        return d
    }

    /// Whether you can change an event: it's in a calendar you can write to, and you organised it (or nobody did).
    func canEdit(_ e: CalEvent) -> Bool {
        guard e.calendar.writable, calendars.contains(where: { $0.id == e.calendar.id }) else { return false }
        guard let o = e.organizer, let s = account(e.calendar.accountId) else { return true }
        return myAddresses(s).contains(o.email.lowercased())
    }

    private weak var store: Store?
    private func account(_ id: String) -> AccountState? { store?.state(id: id) }

    nonisolated private static func dateLines(_ d: Draft) -> [String] {
        if d.allDay {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = Foundation.Calendar(identifier: .gregorian)
            f.dateFormat = "yyyyMMdd"
            let cal = Foundation.Calendar.current
            let first = cal.startOfDay(for: d.start)
            let last = max(first, cal.startOfDay(for: d.end))
            let after = cal.date(byAdding: .day, value: 1, to: last) ?? last
            return ["DTSTART;VALUE=DATE:\(f.string(from: first))", "DTEND;VALUE=DATE:\(f.string(from: after))"]
        }
        let end = d.end > d.start ? d.end : d.start.addingTimeInterval(1_800)
        return ["DTSTART:\(ICal.stamp(d.start))", "DTEND:\(ICal.stamp(end))"]
    }

    nonisolated private static func line(_ text: String) -> ICalProperty? { ICal.property(text) }

    func save(_ d: Draft, store: Store) async throws {
        self.store = store
        UserDefaults.standard.set(d.calendarId, forKey: "calendarLastUsed")
        let title = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let e = d.editing {
            try await change(e) { v in
                guard let master = v.events.first(where: { $0.text("UID") == e.uid && $0.prop("RECURRENCE-ID") == nil }) ?? v.events.first else { return }
                func set(_ name: String, _ value: String) {
                    master.properties.removeAll { $0.name == name }
                    if !value.isEmpty, let p = Self.line("\(name):\(ICal.escape(value))") { master.properties.append(p) }
                }
                set("SUMMARY", title)
                set("LOCATION", d.location)
                set("DESCRIPTION", d.notes)
                // A repeating event keeps its times (changing the whole series's times needs more care than a form).
                if !e.repeats {
                    master.properties.removeAll { ["DTSTART", "DTEND", "DURATION"].contains($0.name) }
                    master.properties += Self.dateLines(d).compactMap(Self.line)
                }
                master.properties.removeAll { $0.name == "DTSTAMP" || $0.name == "LAST-MODIFIED" }
                master.properties += ["DTSTAMP:\(ICal.stamp(Date()))", "LAST-MODIFIED:\(ICal.stamp(Date()))"].compactMap(Self.line)
                let seq = Int(master.text("SEQUENCE") ?? "") ?? 0
                master.properties.removeAll { $0.name == "SEQUENCE" }
                if let p = Self.line("SEQUENCE:\(seq + 1)") { master.properties.append(p) }
            }
            return
        }
        guard let c = calendars.first(where: { $0.id == d.calendarId }) else { throw CalDAVError.notFound }
        let uid = UUID().uuidString.lowercased()
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//JMAP Connect//EN", "BEGIN:VEVENT", "UID:\(uid)",
                     "DTSTAMP:\(ICal.stamp(Date()))", "CREATED:\(ICal.stamp(Date()))", "SUMMARY:\(ICal.escape(title))"]
        lines += Self.dateLines(d)
        if !d.location.isEmpty { lines.append("LOCATION:\(ICal.escape(d.location))") }
        if !d.notes.isEmpty { lines.append("DESCRIPTION:\(ICal.escape(d.notes))") }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        guard let v = ICal.parse(lines.joined(separator: "\r\n")) else { return }
        let text = ICal.serialize(v)
        let folder = c.href.hasSuffix("/") ? c.href : c.href + "/"
        let href = folder + uid + ".ics"
        if let s = account(c.accountId), s.account.kind == Demo.kind {
            resources[c.id, default: []].append(CalendarResource(href: href, etag: nil, ics: text))
            reparse()
            return
        }
        guard let s = account(c.accountId), let client = Self.client(for: s) else { throw CalDAVError.http(401) }
        try await client.put(href, ics: text, etag: nil)
        try await reload(c, client: client)
    }

    /// Deletes an event, or with `onlyThis` just this one time of a repeating event.
    func delete(_ e: CalEvent, onlyThis: Bool, store: Store) async throws {
        self.store = store
        if onlyThis && e.repeats {
            try await change(e) { v in
                guard let master = v.events.first(where: { $0.text("UID") == e.uid && $0.prop("RECURRENCE-ID") == nil }) else { return }
                let when: String
                if e.allDay {
                    let f = DateFormatter()
                    f.locale = Locale(identifier: "en_US_POSIX")
                    f.dateFormat = "yyyyMMdd"
                    when = "EXDATE;VALUE=DATE:\(f.string(from: e.start))"
                } else {
                    when = "EXDATE:\(ICal.stamp(e.start))"
                }
                if let p = Self.line(when) { master.properties.append(p) }
                // A moved copy of this one time goes too.
                v.children.removeAll { c in
                    c.name == "VEVENT" && c.text("UID") == e.uid && c.prop("RECURRENCE-ID").flatMap { ICal.when($0)?.date } == e.start
                }
            }
            return
        }
        guard let c = calendars.first(where: { $0.id == e.calendar.id }) else { return }
        if let s = account(c.accountId), s.account.kind == Demo.kind {
            resources[c.id]?.removeAll { $0.href == e.href }
            reparse()
            return
        }
        guard let s = account(c.accountId), let client = Self.client(for: s) else { throw CalDAVError.http(401) }
        try await client.delete(e.href, etag: resources[c.id]?.first { $0.href == e.href }?.etag)
        try await reload(c, client: client)
    }

    /// Reads an event's file, changes it and saves it back (only if nobody changed it meanwhile).
    private func change(_ e: CalEvent, _ edit: (ICalComponent) -> Void) async throws {
        guard let c = calendars.first(where: { $0.id == e.calendar.id }),
              let i = resources[c.id]?.firstIndex(where: { $0.href == e.href }),
              let r = resources[c.id]?[i], let v = ICal.parse(r.ics) else { throw CalDAVError.notFound }
        edit(v)
        let text = ICal.serialize(v)
        if let s = account(c.accountId), s.account.kind == Demo.kind {
            resources[c.id]?[i].ics = text
            reparse()
            return
        }
        guard let s = account(c.accountId), let client = Self.client(for: s) else { throw CalDAVError.http(401) }
        try await client.put(r.href, ics: text, etag: r.etag)
        try await reload(c, client: client)
    }

    private func reload(_ c: CalendarInfo, client: CalDAVClient) async throws {
        resources[c.id] = try await client.events(c.href, from: window.start, to: window.end)
        if let home = homes[c.accountId] {
            let mine = calendars.filter { $0.accountId == c.accountId }
            CalendarDisk.write(c.accountId, CalendarDisk.Saved(home: home, calendars: mine,
                                                                 resources: resources.filter { k, _ in mine.contains { $0.id == k } }))
        }
        extra = [:]
        fetchedExtra = []
        reparse()
    }

    // MARK: Sample mail (App Review and screenshots)

    private func loadSample(_ s: AccountState) {
        let info = CalendarInfo(accountId: s.id, href: "/sample/calendar/", name: "Calendar", colour: "#2F5BD3", ctag: "1", events: true, writable: true)
        let work = CalendarInfo(accountId: s.id, href: "/sample/work/", name: "Work", colour: "#2E9E5B", ctag: "1", events: true, writable: true)
        calendars.removeAll { $0.accountId == s.id }
        calendars += [info, work]
        resources[info.id] = SampleCalendar.personal()
        resources[work.id] = SampleCalendar.work()
    }

    private func answerSample(uid: String, invite: ICalComponent, status: String, mine: Set<String>, account s: AccountState) throws {
        guard let c = calendars.first(where: { $0.accountId == s.id && $0.href == "/sample/work/" }) else { return }
        var list = resources[c.id] ?? []
        if let i = list.firstIndex(where: { ICal.parse($0.ics)?.events.first?.text("UID") == uid }), let v = ICal.parse(list[i].ics) {
            guard Self.setAnswer(v, status: status, mine: mine) else { throw CalDAVError.notInvited }
            list[i].ics = ICal.serialize(v)
        } else if let v = ICal.parse(ICal.serialize(invite)) {
            v.properties.removeAll { $0.name == "METHOD" }
            guard Self.setAnswer(v, status: status, mine: mine) else { throw CalDAVError.notInvited }
            list.append(CalendarResource(href: "/sample/work/\(uid).ics", etag: nil, ics: ICal.serialize(v)))
        }
        resources[c.id] = list
        reparse()
    }
}

/// The calendar kept on the device, one file per account.
enum CalendarDisk {
    struct Saved: Codable {
        var home: CalendarHome
        var calendars: [CalendarInfo]
        var resources: [String: [CalendarResource]]
    }

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Calendar", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            try? dir.setResourceValues(v)
        }
        return dir
    }

    static func file(_ account: String) -> URL { folder.appendingPathComponent(account + ".json") }

    static func read(_ account: String) -> Saved? {
        guard let data = try? Data(contentsOf: file(account)) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    static func write(_ account: String, _ saved: Saved) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        #if os(iOS)
        try? data.write(to: file(account), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: file(account), options: .atomic)
        #endif
    }
}

/// A believable week for sample mail, made fresh around today so it never looks out of date.
enum SampleCalendar {
    private static func stamp(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> String {
        var cal = Foundation.Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let monday = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let day = cal.date(byAdding: .day, value: dayOffset, to: monday)!
        let d = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        return ICal.stamp(d)
    }
    private static func day(_ dayOffset: Int) -> String {
        var cal = Foundation.Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let monday = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let d = cal.date(byAdding: .day, value: dayOffset, to: monday)!
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: d)
    }
    private static func event(_ uid: String, _ lines: [String]) -> CalendarResource {
        let text = (["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//JMAP Connect//Sample//EN", "BEGIN:VEVENT", "UID:\(uid)",
                     "DTSTAMP:\(stamp(0, 8))"] + lines + ["END:VEVENT", "END:VCALENDAR"]).joined(separator: "\r\n")
        return CalendarResource(href: "/sample/\(uid).ics", etag: "1", ics: text)
    }

    static func personal() -> [CalendarResource] {
        [
            event("sample-gym", ["SUMMARY:Gym", "DTSTART:\(stamp(0, 7))", "DTEND:\(stamp(0, 8))", "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"]),
            event("sample-dinner", ["SUMMARY:Dinner with Maya", "LOCATION:The Fig Tree, Bristol", "DTSTART:\(stamp(4, 19))", "DTEND:\(stamp(4, 21, 30))"]),
            event("sample-market", ["SUMMARY:Farmers' market", "DTSTART;VALUE=DATE:\(day(5))", "DTEND;VALUE=DATE:\(day(6))"]),
        ]
    }

    static func work() -> [CalendarResource] {
        [
            event("sample-standup", ["SUMMARY:Team stand up", "DTSTART:\(stamp(0, 9, 30))", "DTEND:\(stamp(0, 9, 45))",
                                     "RRULE:FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR", "LOCATION:https://meet.google.com/abc-defg-hij"]),
            event("sample-review", ["SUMMARY:Spring launch review", "DTSTART:\(stamp(3, 14))", "DTEND:\(stamp(3, 15))",
                                    "ORGANIZER;CN=Maya Chen:mailto:maya@studio-north.example",
                                    "ATTENDEE;CN=Maya Chen;PARTSTAT=ACCEPTED:mailto:maya@studio-north.example",
                                    "ATTENDEE;CN=Sam Taylor;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:sam@example.com",
                                    "DESCRIPTION:Walk through the final designs and agree the launch date."]),
            event("sample-oneone", ["SUMMARY:One to one with Alex", "DTSTART:\(stamp(1, 11))", "DTEND:\(stamp(1, 11, 30))"]),
            event("sample-openday", ["SUMMARY:Studio open day", "DTSTART;VALUE=DATE:\(day(2))", "DTEND;VALUE=DATE:\(day(3))"]),
        ]
    }
}
