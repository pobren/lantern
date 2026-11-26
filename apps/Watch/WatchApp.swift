// JMAP Connect for Apple Watch (1.2): every inbox in one list, read an email, star it, archive it and reply by voice
// or with a quick reply. The iPhone app hands over its accounts; the Watch then talks to the mail server itself, and
// with its own Fastmail sign in (Settings, Apple Watch on the iPhone) it keeps working away from the iPhone.

import SwiftUI
import WatchConnectivity
import WidgetKit

@main
struct JMAPConnectWatch: App {
    @StateObject private var mail = WatchStore()

    var body: some Scene {
        WindowGroup {
            InboxView().environmentObject(mail)
        }
    }
}

@MainActor
final class WatchStore: NSObject, ObservableObject, WCSessionDelegate {
    @Published var emails: [WatchEmail] = []
    @Published var unread = 0
    @Published var loading = false
    @Published var problem: String?
    @Published var accounts: [WatchAccount] = WatchAccounts.all
    @Published var sample = WatchAccounts.sample
    private var clients: [String: WatchJMAP] = [:]

    override init() {
        super.init()
        WatchAccounts.canRefresh = true
        // The last inbox, so the list shows at once (and without signal) while the new one loads.
        if !sample, let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let saved = try? JSONDecoder().decode([WatchEmail].self, from: data) {
            emails = saved
            unread = UserDefaults.standard.integer(forKey: Self.cacheKey + ".unread")
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    var hasMail: Bool { !accounts.isEmpty || sample }
    private static let cacheKey = "watch.inbox"
    @Published var replies: [String] = WatchAccounts.replies

    private func client(_ id: String) -> WatchJMAP? {
        if let c = clients[id] { return c }
        guard let a = accounts.first(where: { $0.id == id }), let c = WatchJMAP(a) else { return nil }
        clients[id] = c
        return c
    }

    func refresh() async {
        if accounts.isEmpty && !sample {
            askPhone()
            return
        }
        if sample && accounts.isEmpty {
            emails = WatchSample.emails()
            unread = emails.filter(\.unread).count
            return
        }
        loading = true
        problem = nil
        var all: [WatchEmail] = []
        var count = 0
        for a in accounts {
            guard let c = client(a.id) else { continue }
            do {
                let got = try await c.inbox()
                all += got.emails
                count += got.unread
            } catch WatchError.signIn {
                // A Fastmail sign in's access token only lasts a while: ask the iPhone for a current one.
                if WCSession.default.isReachable { askPhone(fresh: true) } else { problem = WatchError.signIn.localizedDescription }
            } catch {
                problem = error.localizedDescription
            }
        }
        if !all.isEmpty || problem == nil {
            emails = all.sorted { $0.date > $1.date }
            unread = count
            if let data = try? JSONEncoder().encode(emails) {
                UserDefaults.standard.set(data, forKey: Self.cacheKey)
                UserDefaults.standard.set(count, forKey: Self.cacheKey + ".unread")
            }
        }
        loading = false
        WidgetCenter.shared.reloadAllTimelines()
    }

    func text(_ e: WatchEmail) async -> String {
        if e.account == WatchSample.account { return e.preview ?? "" }
        guard let c = client(e.account) else { return e.preview ?? "" }
        return (try? await c.text(e.id)).flatMap { $0.isEmpty ? nil : $0 } ?? (e.preview ?? "")
    }

    private func change(_ e: WatchEmail, _ edit: (inout WatchEmail) -> Void) {
        if let i = emails.firstIndex(where: { $0.key == e.key }) { edit(&emails[i]) }
    }

    func markRead(_ e: WatchEmail, _ read: Bool = true) async {
        guard e.unread == read else { return }
        change(e) { $0.keywords = ($0.keywords ?? [:]).merging(["$seen": read]) { _, n in n } }
        unread = max(0, unread + (read ? -1 : 1))
        if e.account != WatchSample.account { try? await client(e.account)?.set(e.id, keyword: "$seen", read) }
        WidgetCenter.shared.reloadAllTimelines()
    }

    func star(_ e: WatchEmail) async {
        let on = !e.starred
        change(e) { $0.keywords = ($0.keywords ?? [:]).merging(["$flagged": on]) { _, n in n } }
        if e.account != WatchSample.account { try? await client(e.account)?.set(e.id, keyword: "$flagged", on) }
    }

    func archive(_ e: WatchEmail) async {
        if e.unread { unread = max(0, unread - 1) }
        emails.removeAll { $0.key == e.key }
        if e.account != WatchSample.account {
            do { try await client(e.account)?.archive(e.id) } catch { problem = error.localizedDescription }
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    func delete(_ e: WatchEmail) async {
        if e.unread { unread = max(0, unread - 1) }
        emails.removeAll { $0.key == e.key }
        if e.account != WatchSample.account {
            do { try await client(e.account)?.delete(e.id) } catch { problem = error.localizedDescription }
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Returns nil when it went, or why it didn't.
    func reply(_ e: WatchEmail, _ text: String) async -> String? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        if e.account == WatchSample.account { return nil }
        guard let c = client(e.account) else { return "Open JMAP Connect on your iPhone first." }
        if !text.isEmpty, let i = emails.firstIndex(where: { $0.key == e.key }) {
            emails[i].keywords = (emails[i].keywords ?? [:]).merging(["$answered": true]) { _, n in n }
        }
        do { try await c.reply(to: e, text: words); return nil } catch { return error.localizedDescription }
    }

    // MARK: iPhone

    private func take(_ context: [String: Any]) {
        guard !context.isEmpty else { return }
        WatchAccounts.take(context)
        clients = [:]
        accounts = WatchAccounts.all
        sample = WatchAccounts.sample
        replies = WatchAccounts.replies
        if accounts.isEmpty {
            emails = []
            UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        }
        Task { await refresh() }
    }

    private var askedFresh = Date.distantPast

    func askPhone(fresh: Bool = false) {
        let s = WCSession.default
        guard s.activationState == .activated else { return }
        if fresh {
            // Once a minute at most, so a server that keeps refusing doesn't loop.
            guard Date().timeIntervalSince(askedFresh) > 60 else { return }
            askedFresh = Date()
        } else if !s.receivedApplicationContext.isEmpty { take(s.receivedApplicationContext); return }
        guard s.isReachable else { return }
        s.sendMessage(["want": "accounts"], replyHandler: { reply in
            Task { @MainActor in self.take(reply) }
        }, errorHandler: nil)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let ctx = session.receivedApplicationContext
        Task { @MainActor in
            if !ctx.isEmpty { self.take(ctx) } else { self.askPhone() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.take(applicationContext) }
    }

    /// The Watch's own Fastmail sign in (or a request to forget it), sent from the iPhone's Settings, Apple Watch.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        WatchAccounts.takeGrant(userInfo)
        Task { @MainActor in
            self.clients = [:]
            await self.refresh()
        }
    }
}

struct InboxView: View {
    @EnvironmentObject var mail: WatchStore
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            Group {
                if !mail.hasMail {
                    ScrollView {
                        VStack(spacing: 10) {
                            Image(systemName: "iphone").font(.title2).foregroundStyle(.tint)
                            Text("Open JMAP Connect on your iPhone and add your mail account. Your inbox then shows here.")
                                .font(.footnote).multilineTextAlignment(.center)
                            Button { mail.askPhone() } label: { Label("Try again", systemImage: "arrow.clockwise") }
                        }
                        .padding(.top, 8)
                    }
                } else if mail.emails.isEmpty && mail.loading {
                    ProgressView()
                } else if mail.emails.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray").font(.title2).foregroundStyle(.secondary)
                        Text(mail.problem ?? "Your inbox is empty.").font(.footnote).multilineTextAlignment(.center)
                    }
                } else {
                    List {
                        if let problem = mail.problem {
                            Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(mail.emails, id: \.key) { e in
                            NavigationLink(value: e) { Row(email: e) }
                                .swipeActions(edge: .trailing) {
                                    Button { Task { await mail.archive(e) } } label: { Label("Archive", systemImage: "archivebox") }
                                        .tint(.blue)
                                }
                                .swipeActions(edge: .leading) {
                                    Button { Task { await mail.markRead(e, e.unread) } } label: {
                                        Label(e.unread ? "Read" : "Unread", systemImage: e.unread ? "envelope.open" : "envelope.badge")
                                    }
                                    .tint(.indigo)
                                }
                        }
                    }
                    .refreshable { await mail.refresh() }
                }
            }
            .navigationTitle(mail.unread > 0 ? "Inbox (\(mail.unread))" : "Inbox")
            .navigationDestination(for: WatchEmail.self) { e in MessageView(email: e) }
        }
        .task { await mail.refresh() }
        .onChange(of: phase) { _, now in if now == .active { Task { await mail.refresh() } } }
    }
}

struct Row: View {
    let email: WatchEmail
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if email.unread { Circle().fill(.tint).frame(width: 6, height: 6).accessibilityLabel("Unread") }
                Text(email.sender.display).font(.headline).lineLimit(1)
                if email.starred { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
            }
            Text(email.title).font(.footnote).lineLimit(2)
            Text(email.date, format: Date.RelativeFormatStyle(presentation: .named, unitsStyle: .abbreviated))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct MessageView: View {
    @EnvironmentObject var mail: WatchStore
    @Environment(\.dismiss) private var dismiss
    let email: WatchEmail
    @State private var text: String?
    @State private var note: String?

    private var current: WatchEmail { mail.emails.first { $0.key == email.key } ?? email }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(current.sender.display).font(.headline)
                Text(current.title).font(.footnote.weight(.semibold))
                Text(current.date, style: .date).font(.caption2).foregroundStyle(.secondary)
                Divider()
                if let text { Text(text).font(.footnote) } else { ProgressView() }
                if let note { Label(note, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary) }
                Divider()
                NavigationLink { ReplyView(email: current, note: $note) } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
                Button { Task { await mail.star(current) } } label: {
                    Label(current.starred ? "Remove star" : "Star", systemImage: current.starred ? "star.slash" : "star")
                }
                Button { Task { await mail.markRead(current, false); dismiss() } } label: {
                    Label("Mark as unread", systemImage: "envelope.badge")
                }
                Button { Task { await mail.archive(current); dismiss() } } label: { Label("Archive", systemImage: "archivebox") }
                Button(role: .destructive) { Task { await mail.delete(current); dismiss() } } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .task {
            text = await mail.text(current)
            await mail.markRead(current)
        }
    }
}

/// Reply: say or type something, or tap one of the quick replies (set on the iPhone in Settings, Apple Watch).
struct ReplyView: View {
    @EnvironmentObject var mail: WatchStore
    @Environment(\.dismiss) private var dismiss
    let email: WatchEmail
    @Binding var note: String?
    @State private var sending = false

    private func send(_ words: String) {
        guard !sending else { return }
        sending = true
        Task {
            note = "Sending…"
            let problem = await mail.reply(email, words)
            note = problem ?? "Sent."
            sending = false
            dismiss()
        }
    }

    var body: some View {
        List {
            TextFieldLink(prompt: Text("Reply to \(email.sender.display)")) {
                Label("Say or type", systemImage: "mic")
            } onSubmit: { words in send(words) }
            Section("Quick replies") {
                ForEach(mail.replies, id: \.self) { r in
                    Button { send(r) } label: { Text(r).lineLimit(3) }
                }
            }
        }
        .disabled(sending)
        .overlay { if sending { ProgressView() } }
        .navigationTitle("Reply")
    }
}
