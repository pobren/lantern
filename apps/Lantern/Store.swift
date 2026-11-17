// The app's state: the accounts, what's in each inbox, and the actions (read, done, later, send).
// Lists come from every account together; each item remembers which account it belongs to.

import Foundation
import SwiftUI

/// An account the person added. Saved in settings; its token is in the Keychain.
struct Account: Codable, Identifiable, Hashable {
    let id: String
    let kind: String          // "fastmail", "mailapp" or "other"
    let sessionURL: String
    var username: String

    var colour: Color { kind == "fastmail" ? Look.fastmail : kind == "mailapp" ? Look.mailApp : Look.other }
    var label: String { kind == "fastmail" ? "Fastmail" : kind == "mailapp" ? "Mail App" : username }
}

/// One email, with the account it came from.
struct Item: Identifiable, Hashable {
    let account: Account
    let email: Email
    var id: String { account.id + "/" + email.id }
}

@MainActor
final class AccountState: ObservableObject, Identifiable {
    let account: Account
    let client: JMAPClient
    @Published var mailboxes: [Mailbox] = []
    @Published var identities: [Identity] = []
    @Published var inbox: [Email] = []
    @Published var sent: [Email] = []
    var id: String { account.id }

    init(account: Account, client: JMAPClient) {
        self.account = account
        self.client = client
    }

    func box(_ role: String) -> Mailbox? { mailboxes.first { $0.role == role } }
}

@MainActor
final class Store: ObservableObject {
    @Published var accounts: [AccountState] = []
    @Published var loading = false
    @Published var problem: String?
    @Published var bodies: [String: String] = [:]
    @Published var laterUntil: [String: Date] = [:]
    @Published var focusDone = 0

    private var listeners: [String: Task<Void, Never>] = [:]
    private let savedKey = "accounts"
    private let laterKey = "later"

    init() {
        if let data = UserDefaults.standard.data(forKey: laterKey), let saved = try? JSONDecoder().decode([String: Date].self, from: data) {
            laterUntil = saved.filter { $0.value > Date() }
        }
        guard let data = UserDefaults.standard.data(forKey: savedKey),
              let saved = try? JSONDecoder().decode([Account].self, from: data) else { return }
        for account in saved {
            guard let token = Keychain.read(account.id), let url = URL(string: account.sessionURL) else { continue }
            accounts.append(AccountState(account: account, client: JMAPClient(sessionURL: url, token: token)))
        }
    }

    var hasAccounts: Bool { !accounts.isEmpty }

    // MARK: Accounts

    func add(kind: ServerKind, address: String, token: String) async throws {
        var session = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if session.isEmpty { session = kind.sessionURL }
        if !session.hasPrefix("http") { session = "https://" + session }
        if !session.contains("/jmap") && !session.contains("well-known") {
            session = session.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/.well-known/jmap"
        }
        guard let url = URL(string: session) else { throw JMAPError.badServer }
        let client = JMAPClient(sessionURL: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        let s = try await client.connect()
        let account = Account(id: UUID().uuidString, kind: kind.id, sessionURL: session, username: s.username)
        Keychain.save(account.id, token.trimmingCharacters(in: .whitespacesAndNewlines))
        let state = AccountState(account: account, client: client)
        accounts.append(state)
        save()
        await load(state)
        listen(state)
    }

    func remove(_ state: AccountState) {
        listeners[state.id]?.cancel()
        listeners[state.id] = nil
        Keychain.delete(state.id)
        accounts.removeAll { $0.id == state.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts.map(\.account)) { UserDefaults.standard.set(data, forKey: savedKey) }
    }

    // MARK: Loading

    func start() async {
        await refresh()
        for state in accounts { listen(state) }
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        for state in accounts { await load(state) }
    }

    private func load(_ state: AccountState) async {
        do {
            if state.client.session == nil { try await state.client.connect() }
            state.mailboxes = try await state.client.mailboxes()
            if state.identities.isEmpty { state.identities = (try? await state.client.identities()) ?? [] }
            if let inbox = state.box("inbox") {
                state.inbox = try await state.client.emails(filter: ["inMailbox": inbox.id], limit: 150)
            }
            if let sent = state.box("sent") {
                state.sent = try await state.client.emails(filter: ["inMailbox": sent.id], limit: 100)
            }
            problem = nil
        } catch {
            problem = "\(state.account.label): \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    /// New mail arrives instantly: the server tells us over JMAP push and we fetch again.
    private func listen(_ state: AccountState) {
        listeners[state.id]?.cancel()
        let client = state.client
        let id = state.id
        listeners[id] = Task { [weak self] in
            await client.listen { [weak self] in
                await self?.reload(id)
            }
        }
    }

    private func reload(_ id: String) async {
        guard let state = accounts.first(where: { $0.id == id }) else { return }
        await load(state)
    }

    // MARK: What the screens show

    var inboxItems: [Item] {
        accounts.flatMap { s in s.inbox.map { Item(account: s.account, email: $0) } }
            .filter { (laterUntil[$0.id] ?? .distantPast) < Date() }
            .sorted { $0.email.date > $1.email.date }
    }

    func pile(_ p: Pile) -> [Item] { inboxItems.filter { Pile.of($0.email) == p } }

    /// What's waiting on you: unread first, then anything in the last two days you haven't dealt with.
    var needsYou: [Item] {
        pile(.needsYou).filter { $0.email.isUnread || $0.email.isFlagged || $0.email.date > Date().addingTimeInterval(-2 * 86_400) }
    }

    /// Focus mode works through unread mail, oldest first, one at a time.
    var focusQueue: [Item] { inboxItems.filter { $0.email.isUnread }.sorted { $0.email.date < $1.email.date } }

    /// People you write with, from the inbox and Sent, newest conversation first. Newsletters and robots stay out.
    var people: [Person] {
        var byEmail: [String: Person] = [:]
        for s in accounts {
            let mine = Set(s.identities.map { $0.email.lowercased() } + [s.account.username.lowercased()])
            for e in s.inbox where !e.isBulk && !e.isAutomated {
                let key = e.sender.email.lowercased()
                guard !key.isEmpty, !mine.contains(key) else { continue }
                byEmail[key, default: Person(address: e.sender, emails: [])].emails.append(e)
            }
            for e in s.sent {
                for to in (e.to ?? []) {
                    let key = to.email.lowercased()
                    guard !mine.contains(key) else { continue }
                    byEmail[key, default: Person(address: to, emails: [])].emails.append(e)
                }
            }
        }
        return byEmail.values.filter { p in p.emails.contains { !$0.mailboxIds.isEmpty } }
            .sorted { ($0.latest?.date ?? .distantPast) > ($1.latest?.date ?? .distantPast) }
    }

    func isMine(_ e: Email) -> Bool {
        accounts.contains { s in
            let mine = Set(s.identities.map { $0.email.lowercased() } + [s.account.username.lowercased()])
            return mine.contains(e.sender.email.lowercased())
        }
    }

    func state(for account: Account) -> AccountState? { accounts.first { $0.id == account.id } }

    // MARK: Actions

    func body(_ item: Item) async -> String {
        if let cached = bodies[item.id] { return cached }
        guard let s = state(for: item.account) else { return item.email.preview ?? "" }
        let text = (try? await s.client.body(of: item.email.id)) ?? (item.email.preview ?? "")
        bodies[item.id] = text
        return text
    }

    func markRead(_ item: Item) async {
        guard item.email.isUnread, let s = state(for: item.account) else { return }
        await act(s) { try await s.client.update([item.email.id: ["keywords/$seen": true]]) }
    }

    /// Done = read and out of the inbox, into Archive.
    func done(_ item: Item) async {
        guard let s = state(for: item.account), let inbox = s.box("inbox") else { return }
        var patch: [String: Any] = ["keywords/$seen": true, "mailboxIds/\(inbox.id)": NSNull()]
        if let archive = s.box("archive") { patch["mailboxIds/\(archive.id)"] = true }
        s.inbox.removeAll { $0.id == item.email.id }
        await act(s) { try await s.client.update([item.email.id: patch]) }
    }

    func flag(_ item: Item) async {
        guard let s = state(for: item.account) else { return }
        await act(s) { try await s.client.update([item.email.id: ["keywords/$flagged": item.email.isFlagged ? NSNull() : true]]) }
    }

    func delete(_ item: Item) async {
        guard let s = state(for: item.account), let inbox = s.box("inbox"), let trash = s.box("trash") else { return }
        s.inbox.removeAll { $0.id == item.email.id }
        await act(s) { try await s.client.update([item.email.id: ["mailboxIds/\(inbox.id)": NSNull(), "mailboxIds/\(trash.id)": true]]) }
    }

    /// Later = out of sight until tomorrow morning at 8, then back in Today and Focus.
    func putOff(_ item: Item) {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        laterUntil[item.id] = cal.date(byAdding: .hour, value: 8, to: tomorrow)
        if let data = try? JSONEncoder().encode(laterUntil) { UserDefaults.standard.set(data, forKey: laterKey) }
    }

    func markAllSeen(_ items: [Item]) async {
        for s in accounts {
            let ids = items.filter { $0.account.id == s.id && $0.email.isUnread }.map(\.email.id)
            guard !ids.isEmpty else { continue }
            await act(s) { try await s.client.update(Dictionary(uniqueKeysWithValues: ids.map { ($0, ["keywords/$seen": true] as [String: Any]) })) }
        }
    }

    func send(account: Account, identity: Identity, to: [EmailAddress], cc: [EmailAddress], subject: String, text: String, replyTo: Email?) async throws {
        guard let s = state(for: account), let drafts = s.box("drafts"), let sent = s.box("sent") else { throw JMAPError.missing("Drafts or Sent") }
        try await s.client.send(from: identity, to: to, cc: cc, subject: subject, text: text,
                                inReplyTo: replyTo?.messageId?.first, drafts: drafts.id, sent: sent.id)
        await load(s)
    }

    private func act(_ s: AccountState, _ work: () async throws -> Void) async {
        do { try await work() } catch { problem = "\(s.account.label): \(error.localizedDescription)" }
        await load(s)
    }
}
