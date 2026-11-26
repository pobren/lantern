// Invitations in the email (1.3): an email carrying a calendar invitation shows the event at the top, with Accept,
// Maybe and Decline. The answer goes into your calendar and the server tells the organiser, as Fastmail's own
// calendar does. Cancellations and replies show what they say.

import SwiftUI
import AuthenticationServices

struct InvitationCard: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var model = CalendarModel.shared
    let files: [Attachment]
    let account: Account
    @Environment(\.webAuthenticationSession) private var webAuth

    @State private var invite: ICalComponent?
    @State private var method = ""
    @State private var event: CalEvent?
    @State private var working: String?
    @State private var answered: String?
    @State private var problem: String?
    @State private var turningOn = false

    /// The calendar file in an email, if there is one.
    static func file(in files: [Attachment]) -> Attachment? {
        files.first { $0.type.lowercased().contains("calendar") || $0.name.lowercased().hasSuffix(".ics") }
    }

    private var state: AccountState? { store.state(for: account) }

    private var me: CalPerson? {
        guard let s = state, let event else { return nil }
        let mine = model.myAddresses(s)
        return event.attendees.first { mine.contains($0.email.lowercased()) }
    }

    var body: some View {
        Group {
            if let event {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        DateTile(date: event.start)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.title).font(.headline).lineLimit(2)
                            Text(CalText.longDay.string(from: event.start) + ", " + event.timeText.lowercasedFirst)
                                .font(.callout).foregroundStyle(.secondary)
                            if !event.location.isEmpty && event.joinLink?.absoluteString != event.location {
                                Text(event.location).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if let o = event.organizer { Text("From \(o.label)").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                        if let link = event.joinLink {
                            Link(destination: link) { Label("Join", systemImage: "video.fill") }
                                .buttonStyle(.bordered)
                        }
                    }
                    footer
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Look.ground))
                .padding(.horizontal, 22).padding(.bottom, 10)
            }
        }
        .task(id: files.map(\.blobId).joined()) { await load() }
    }

    @ViewBuilder private var footer: some View {
        switch method {
        case "CANCEL":
            Label("This event has been cancelled.", systemImage: "calendar.badge.minus").font(.callout).foregroundStyle(.red)
        case "REPLY":
            if let p = event?.attendees.first {
                Label("\(p.label) \(Self.said(p.status)).", systemImage: "envelope.badge").font(.callout).foregroundStyle(.secondary)
            }
        default:
            if let me, let s = state {
                if CalendarModel.client(for: s) == nil && s.account.kind == "fastmail" {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("To answer from here, approve calendar access with Fastmail once.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button {
                            turningOn = true
                            Task { await model.turnOn(s, using: webAuth, store: store); turningOn = false }
                        } label: { Label(turningOn ? "Waiting for Fastmail" : "Turn on calendar", systemImage: "calendar.badge.plus") }
                            .buttonStyle(.borderedProminent)
                            .disabled(turningOn)
                    }
                } else {
                    AnswerButtons(current: answered ?? model.myAnswer(uid: event?.uid ?? "", account: s) ?? me.status, working: working) { status in
                        Task { await answer(status) }
                    }
                }
                if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
            }
        }
    }

    static func said(_ status: String) -> String {
        switch status {
        case "ACCEPTED": return "accepted"
        case "DECLINED": return "declined"
        case "TENTATIVE": return "said maybe"
        default: return "replied"
        }
    }

    private func load() async {
        guard let file = Self.file(in: files), let s = state else { return }
        let data: Data?
        if let url = await store.file(file, account: account) { data = try? Data(contentsOf: url) } else { data = nil }
        guard let data, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let v = ICal.parse(text), let first = v.events.first(where: { $0.prop("RECURRENCE-ID") == nil }) ?? v.events.first,
              let startProp = first.prop("DTSTART"), let start = ICal.when(startProp) else { return }
        let length: TimeInterval = first.prop("DTEND").flatMap { ICal.when($0) }.map { $0.date.timeIntervalSince(start.date) }
            ?? first.text("DURATION").flatMap(ICal.duration) ?? (start.allDay ? 86_400 : 3_600)
        let info = CalendarInfo(accountId: s.id, href: "invitation", name: "Invitation", colour: nil, ctag: nil, events: true, writable: false)
        invite = v
        method = (v.text("METHOD") ?? "REQUEST").uppercased()
        event = CalExpand.make(first, calendar: info, href: "invitation", start: start.date, end: start.date.addingTimeInterval(length),
                               allDay: start.allDay, repeats: first.prop("RRULE") != nil)
    }

    private func answer(_ status: String) async {
        guard let invite, let s = state else { return }
        working = status; problem = nil
        defer { working = nil }
        do {
            try await model.respond(invite, status: status, account: s, store: store)
            answered = status
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// A small calendar page: the month and the day number.
private struct DateTile: View {
    let date: Date
    var body: some View {
        VStack(spacing: 0) {
            Text(CalText.f("MMM").string(from: date).uppercased())
                .font(.caption2.weight(.bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 2)
                .background(Color.red)
            Text(CalText.dayNumber.string(from: date)).font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 3)
        }
        .frame(width: 46)
        .background(Look.paper)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Look.line, lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

extension String {
    var lowercasedFirst: String {
        guard let f = first else { return self }
        // "All day" reads "all day" after a comma; times are left alone.
        return f.isUppercase ? f.lowercased() + dropFirst() : self
    }
}
