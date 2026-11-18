// The app's state: the accounts and their folders, the list on screen, the open conversation, and every action
// (read, star, archive, move, delete, send). Lists can mix accounts; each item remembers where it came from.

import Foundation
import SwiftUI

/// An account the person added. Saved in settings; its token is in the Keychain.
struct Account: Codable, Identifiable, Hashable {
    let id: String
    let kind: String          // "fastmail", "mailapp" or "other"
    let sessionURL: String
    var username: String

    var colour: Color { kind == "fastmail" ? Look.fastmail : kind == "mailapp" ? Look.mailApp : Look.other }
    var kindName: String { kind == "fastmail" ? "Fastmail" : kind == "mailapp" ? "Mail App" : "JMAP" }
    var label: String { username.isEmpty ? (kind == "fastmail" ? "Fastmail" : kind == "mailapp" ? "Mail App" : "Mail") : username }
}

/// One email (in a list, the newest of its conversation), with the account it came from.
struct Item: Identifiable, Hashable {
    let account: Account
    let email: Email
    var id: String { account.id + "/" + email.id }
}

/// Points at one email, for opening it in a window of its own.
struct MessageRef: Codable, Hashable {
    let account: String
    let email: String
}

/// What the middle column shows: every inbox together, or one folder of one account.
enum Folder: Hashable {
    case allInboxes
    case mailbox(account: String, id: String)
}

@MainActor
final class AccountState: ObservableObject, Identifiable {
    let account: Account
    let client: JMAPClient
    @Published var mailboxes: [Mailbox] = []
    @Published var identities: [Identity] = []
    @Published var inbox: [Email] = []
    var id: String { account.id }

    init(account: Account, client: JMAPClient) {
        self.account = account
        self.client = client
    }

    func box(_ role: String) -> Mailbox? { mailboxes.first { $0.role == role } }
    func box(id: String) -> Mailbox? { mailboxes.first { $0.id == id } }

    /// Folders in sidebar order, each with how deep it sits under its parents.
    var tree: [FolderEntry] {
        var out: [FolderEntry] = []
        var trail: [String] = []
        func add(_ parent: String?, _ depth: Int) {
            let children = mailboxes.filter { $0.parentId == parent }
                .sorted { ($0.rank, $0.sortOrder ?? 0, $0.name.lowercased()) < ($1.rank, $1.sortOrder ?? 0, $1.name.lowercased()) }
            for c in children {
                out.append(FolderEntry(box: c, depth: depth, ancestors: trail,
                                       hasChildren: mailboxes.contains { $0.parentId == c.id }))
                trail.append(c.id)
                add(c.id, depth + 1)
                trail.removeLast()
            }
        }
        add(nil, 0)
        return out
    }
}

/// A folder in the sidebar, with how far it is indented under its parents.
struct FolderEntry: Identifiable {
    let box: Mailbox
    let depth: Int
    let ancestors: [String]   // the folders it sits inside, outermost first
    let hasChildren: Bool
    var id: String { box.id }
}

@MainActor
final class Store: ObservableObject {
    @Published var accounts: [AccountState] = []
    @Published var problem: String?

    // The middle column.
    @Published var folder: Folder = .allInboxes
    @Published var list: [Item] = []
    @Published var listLoading = false
    @Published var search = ""
    private var listLimit = 100
    @Published var mayHaveMore = false

    // The reading pane.
    @Published var selection: Item.ID?

    // Folders whose subfolders are tucked away in the sidebar, as "account/folder".
    @Published var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsed") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "collapsed") }
    }

    private var listeners: [String: Task<Void, Never>] = [:]
    private let savedKey = "accounts"

    init() {
        guard let data = UserDefaults.standard.data(forKey: savedKey),
              let saved = try? JSONDecoder().decode([Account].self, from: data) else { return }
        for account in saved {
            guard let token = Keychain.read(account.id), let url = URL(string: account.sessionURL) else { continue }
            accounts.append(AccountState(account: account, client: JMAPClient(sessionURL: url, token: token)))
        }
    }

    var hasAccounts: Bool { !accounts.isEmpty }
    func state(for account: Account) -> AccountState? { accounts.first { $0.id == account.id } }
    func state(id: String) -> AccountState? { accounts.first { $0.id == id } }
    var selectedItem: Item? { list.first { $0.id == selection } }

    // MARK: Accounts

    func add(kind: ServerKind, address: String, token: String) async throws {
        var session = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if session.isEmpty { session = kind.sessionURL }
        if !session.hasPrefix("http") { session = "https://" + session }
        if !session.contains("/jmap") && !session.contains("well-known") {
            session = session.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/.well-known/jmap"
        }
        guard let url = URL(string: session) else { throw JMAPError.badServer }
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = JMAPClient(sessionURL: url, token: secret)
        let s = try await client.connect()
        let account = Account(id: UUID().uuidString, kind: kind.id, sessionURL: session, username: s.username)
        Keychain.save(account.id, secret)
        let state = AccountState(account: account, client: client)
        accounts.append(state)
        save()
        await load(state)
        listen(state)
        await reloadList()
    }

    func remove(_ state: AccountState) {
        listeners[state.id]?.cancel()
        listeners[state.id] = nil
        Keychain.delete(state.id)
        accounts.removeAll { $0.id == state.id }
        if case .mailbox(let account, _) = folder, account == state.id { folder = .allInboxes }
        save()
        Task { await reloadList() }
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
        await withTaskGroup(of: Void.self) { group in
            for state in accounts { group.addTask { await self.load(state) } }
        }
        await reloadList()
    }

    /// Folders, addresses and the inbox for one account.
    private func load(_ state: AccountState) async {
        do {
            if state.client.session == nil { try await state.client.connect() }
            state.mailboxes = try await state.client.mailboxes()
            if state.identities.isEmpty { state.identities = (try? await state.client.identities()) ?? [] }
            if let inbox = state.box("inbox") {
                state.inbox = try await state.client.emails(filter: ["inMailbox": inbox.id], limit: 100)
                Notifier.newMail(in: state.inbox, account: state.account)
            }
            problem = nil
        } catch {
            problem = "\(state.account.label): \(error.localizedDescription)"
        }
        objectWillChange.send()
        Notifier.badge(unreadInboxes)
    }

    /// For iPhone and iPad in the background: check every inbox once, notify about anything new, update the badge.
    func backgroundCheck() async {
        for state in accounts { await load(state) }
    }

    /// New mail arrives instantly: the server tells us over JMAP push and we fetch again.
    private func listen(_ state: AccountState) {
        listeners[state.id]?.cancel()
        let client = state.client
        let id = state.id
        listeners[id] = Task { [weak self] in
            await client.listen { [weak self] in
                await self?.changed(id)
            }
        }
    }

    private func changed(_ id: String) async {
        guard let state = state(id: id) else { return }
        await load(state)
        switch folder {
        case .allInboxes: await reloadList(quietly: true)
        case .mailbox(let account, _) where account == id: await reloadList(quietly: true)
        default: break
        }
    }

    // MARK: The list

    func open(_ f: Folder) async {
        guard f != folder || list.isEmpty else { return }
        folder = f
        selection = nil
        list = []
        listLimit = 100
        await reloadList()
    }

    func loadMore() async {
        guard mayHaveMore, !listLoading else { return }
        listLimit += 100
        await reloadList(quietly: true)
    }

    /// Fetches the middle column again: the folder on screen, narrowed by the search box if anything is typed in it.
    func reloadList(quietly: Bool = false) async {
        if !quietly { listLoading = true }
        defer { listLoading = false }
        let words = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = folder
        var items: [Item] = []
        switch wanted {
        case .allInboxes:
            if words.isEmpty && listLimit <= 100 {
                items = accounts.flatMap { s in s.inbox.map { Item(account: s.account, email: $0) } }
            } else {
                for s in accounts {
                    guard let inbox = s.box("inbox") else { continue }
                    var filter: [String: Any] = ["inMailbox": inbox.id]
                    if !words.isEmpty { filter["text"] = words }
                    do {
                        items += try await s.client.emails(filter: filter, limit: listLimit).map { Item(account: s.account, email: $0) }
                    } catch { problem = "\(s.account.label): \(error.localizedDescription)" }
                }
            }
        case .mailbox(let accountId, let boxId):
            guard let s = state(id: accountId) else { break }
            var filter: [String: Any] = ["inMailbox": boxId]
            if !words.isEmpty { filter["text"] = words }
            do {
                items = try await s.client.emails(filter: filter, limit: listLimit).map { Item(account: s.account, email: $0) }
            } catch { problem = "\(s.account.label): \(error.localizedDescription)" }
        }
        guard wanted == folder else { return }       // the person moved on while this was loading
        list = items.sorted { $0.email.date > $1.email.date }
        mayHaveMore = items.count >= listLimit
    }

    var folderTitle: String {
        switch folder {
        case .allInboxes: return accounts.count > 1 ? "All inboxes" : "Inbox"
        case .mailbox(let a, let id): return state(id: a)?.box(id: id)?.name ?? "Mail"
        }
    }

    /// Unread across every inbox, for the sidebar and the Dock.
    var unreadInboxes: Int {
        accounts.reduce(0) { $0 + ($1.box("inbox")?.unreadEmails ?? 0) }
    }

    /// The folder an item is being looked at in, so archive and move know where to take it from.
    private func source(for item: Item, in s: AccountState) -> Mailbox? {
        if case .mailbox(let a, let id) = folder, a == s.id { return s.box(id: id) }
        return s.box("inbox")
    }

    // MARK: Reading

    private var pages: [String: (html: String, attachments: [Attachment])] = [:]

    func conversation(_ item: Item) async -> [Email] {
        guard let s = state(for: item.account) else { return [item.email] }
        let all = (try? await s.client.thread(item.email.threadId)) ?? [item.email]
        // Keep drafts and anything in the bin out of a conversation, unless that's where you're looking.
        let trash = s.box("trash")?.id
        let lookingInTrash = source(for: item, in: s)?.role == "trash"
        let shown = all.filter { e in !e.isDraft && (lookingInTrash || trash == nil || e.mailboxIds.keys.contains { $0 != trash }) }
        return shown.isEmpty ? [item.email] : shown
    }

    /// The email laid out as its sender designed it, plus its attachments.
    func page(_ email: Email, account: Account) async -> (html: String, attachments: [Attachment])? {
        let key = account.id + "/" + email.id
        if let cached = pages[key] { return cached }
        guard let s = state(for: account), let page = try? await s.client.page(of: email.id) else { return nil }
        pages[key] = page
        return page
    }

    func text(_ email: Email, account: Account) async -> String {
        guard let s = state(for: account) else { return email.preview ?? "" }
        return (try? await s.client.body(of: email.id)) ?? (email.preview ?? "")
    }

    /// Saves an attachment to a temporary file, ready to preview or share.
    func file(_ a: Attachment, account: Account) async -> URL? {
        guard let s = state(for: account) else { return nil }
        do {
            let data = try await s.client.download(blobId: a.blobId, type: a.type)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(a.blobId, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let safe = a.name.replacingOccurrences(of: "/", with: "-")
            let url = folder.appendingPathComponent(safe.isEmpty ? "Attachment" : safe)
            try data.write(to: url)
            return url
        } catch {
            problem = "Couldn't open \(a.name): \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Actions

    func markRead(_ emails: [Email], account: Account) async {
        let ids = emails.filter(\.isUnread).map(\.id)
        guard !ids.isEmpty, let s = state(for: account) else { return }
        replace(account: account, ids: Set(ids)) { $0.with(keyword: "$seen", on: true) }
        await act(s, reloadList: false) {
            try await s.client.update(Dictionary(uniqueKeysWithValues: ids.map { ($0, ["keywords/$seen": true] as [String: Any]) }))
        }
    }

    func setUnread(_ item: Item, _ unread: Bool) async {
        guard let s = state(for: item.account) else { return }
        replace(account: item.account, ids: [item.email.id]) { $0.with(keyword: "$seen", on: !unread) }
        await act(s, reloadList: false) { try await s.client.update([item.email.id: ["keywords/$seen": unread ? NSNull() as Any : true as Any]]) }
    }

    func flag(_ item: Item) async {
        guard let s = state(for: item.account) else { return }
        let on = !item.email.isFlagged
        replace(account: item.account, ids: [item.email.id]) { $0.with(keyword: "$flagged", on: on) }
        await act(s, reloadList: false) { try await s.client.update([item.email.id: ["keywords/$flagged": on ? true as Any : NSNull() as Any]]) }
    }

    func archive(_ item: Item) async {
        guard let s = state(for: item.account) else { return }
        guard let archive = s.box("archive") else { problem = "\(item.account.label) has no Archive folder."; return }
        await move(item, to: archive, keepLabels: true)
    }

    func delete(_ item: Item) async {
        guard let s = state(for: item.account), let trash = s.box("trash") else { return }
        if source(for: item, in: s)?.id == trash.id {
            problem = "That conversation is already in the bin."
            return
        }
        await move(item, to: trash)
    }

    /// Whether you're looking at this conversation in Spam, so the button offers Not spam instead.
    func inSpam(_ item: Item) -> Bool {
        guard let s = state(for: item.account) else { return false }
        return source(for: item, in: s)?.role == "junk"
    }

    /// Mark as spam moves the conversation to Spam; Not spam moves it back to the Inbox. The $junk and $notjunk
    /// keywords tell Fastmail's spam filter, so it learns from it, the same as doing it on the web.
    func markSpam(_ item: Item, _ spam: Bool) async {
        guard let s = state(for: item.account) else { return }
        guard let target = s.box(spam ? "junk" : "inbox") else { problem = "\(item.account.label) has no \(spam ? "Spam" : "Inbox") folder."; return }
        let keys: [String: Any] = spam ? ["keywords/$junk": true, "keywords/$notjunk": NSNull()] : ["keywords/$notjunk": true, "keywords/$junk": NSNull()]
        await move(item, to: target, also: keys)
    }

    /// Moves the whole conversation out of the folder you're looking at and into another one.
    /// Works the same whether someone uses Fastmail with folders or with labels, where one email can sit in
    /// several mailboxes at once:
    /// - Bin and Spam take every label off, so a binned email doesn't linger under its other labels.
    /// - Archive (keepLabels) only takes the Inbox label off, and files it in Archive when nothing else is left.
    /// - Any other move swaps the label you're looking at for the new one and keeps the rest.
    /// With folders an email is only ever in one mailbox, so all three come out the same as a plain move.
    func move(_ item: Item, to target: Mailbox, also extra: [String: Any] = [:], keepLabels: Bool = false) async {
        guard let s = state(for: item.account), let from = source(for: item, in: s), from.id != target.id else { return }
        let thread = (try? await s.client.thread(item.email.threadId)) ?? [item.email]
        var emails = thread.filter { $0.mailboxIds[from.id] == true }
        if emails.isEmpty { emails = [item.email] }
        let exclusive = target.role == "trash" || target.role == "junk"
        var patches: [String: [String: Any]] = [:]
        for e in emails {
            var patch: [String: Any]
            if exclusive {
                patch = ["mailboxIds": [target.id: true]]
            } else if keepLabels && e.mailboxIds.keys.contains(where: { $0 != from.id && $0 != target.id }) {
                patch = ["mailboxIds/\(from.id)": NSNull()]
            } else {
                patch = ["mailboxIds/\(from.id)": NSNull(), "mailboxIds/\(target.id)": true]
            }
            patches[e.id] = patch.merging(extra) { a, _ in a }
        }
        takeOut(item)
        if from.role == "inbox" || exclusive { s.inbox.removeAll { $0.threadId == item.email.threadId } }
        await act(s, reloadList: false) {
            try await s.client.update(patches)
        }
    }

    /// The In-Reply-To and References headers for an answer to this email.
    nonisolated static func threading(_ replyTo: Email?) -> (inReplyTo: String?, references: [String]) {
        (replyTo?.messageId?.first, replyTo?.references ?? [])
    }

    func send(account: Account, identity: Identity, as address: String? = nil, to: [EmailAddress], cc: [EmailAddress], bcc: [EmailAddress] = [], subject: String, text: String,
              threading: (inReplyTo: String?, references: [String]), attachments: [Outgoing] = [], replacing: String? = nil) async throws {
        guard let s = state(for: account), let drafts = s.box("drafts"), let sent = s.box("sent") else { throw JMAPError.missing("Drafts or Sent") }
        try await s.client.send(from: identity, as: address, to: to, cc: cc, bcc: bcc, subject: subject, text: text,
                                inReplyTo: threading.inReplyTo, references: threading.references,
                                attachments: attachments, drafts: drafts.id, sent: sent.id, replacing: replacing)
        await load(s)
    }

    /// Keeps an unfinished email in the account's Drafts folder. Returns the saved draft's id.
    @discardableResult
    func saveDraft(account: Account, identity: Identity, as address: String? = nil, to: [EmailAddress], cc: [EmailAddress], bcc: [EmailAddress], subject: String, text: String,
                   threading: (inReplyTo: String?, references: [String]), attachments: [Outgoing], replacing: String?) async throws -> String {
        guard let s = state(for: account), let drafts = s.box("drafts") else { throw JMAPError.missing("a Drafts folder") }
        let id = try await s.client.saveDraft(from: identity, as: address, to: to, cc: cc, bcc: bcc, subject: subject, text: text,
                                              inReplyTo: threading.inReplyTo, references: threading.references,
                                              attachments: attachments, drafts: drafts.id, replacing: replacing)
        await load(s)
        return id
    }

    /// Whether this email is a saved draft you can pick up and carry on writing.
    func isEditableDraft(_ item: Item, _ e: Email) -> Bool {
        guard e.isDraft, let s = state(for: item.account), let drafts = s.box("drafts") else { return false }
        return e.mailboxIds[drafts.id] == true
    }

    /// Puts a file on the account's server, ready to attach. Big files are turned away before they're sent.
    func attach(_ data: Data, name: String, type: String, account: Account) async throws -> Outgoing {
        guard let s = state(for: account) else { throw JMAPError.missing("an account") }
        guard data.count <= 25_000_000 else { throw AttachError.tooBig(name) }
        let blobId = try await s.client.upload(data, type: type)
        return Outgoing(blobId: blobId, name: name, type: type, size: data.count)
    }

    // MARK: Folders

    func isCollapsed(_ box: Mailbox, in s: AccountState) -> Bool { collapsed.contains(s.id + "/" + box.id) }

    func toggleCollapsed(_ box: Mailbox, in s: AccountState) {
        let key = s.id + "/" + box.id
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }

    /// Hidden when any folder it sits inside is collapsed.
    func isHidden(_ entry: FolderEntry, in s: AccountState) -> Bool {
        entry.ancestors.contains { collapsed.contains(s.id + "/" + $0) }
    }

    func newFolder(_ name: String, in s: AccountState, inside parent: Mailbox?) async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let parent { collapsed.remove(s.id + "/" + parent.id) }
        await act(s, reloadList: false) { try await s.client.createMailbox(name: clean, parentId: parent?.id) }
    }

    func rename(_ box: Mailbox, to name: String, in s: AccountState) async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != box.name else { return }
        await act(s, reloadList: false) { try await s.client.renameMailbox(id: box.id, name: clean) }
    }

    /// A conversation dropped on a folder in the sidebar. Only folders of the same account take it.
    func drop(_ ids: [String], on box: Mailbox, in s: AccountState) async -> Bool {
        let items = ids.compactMap { id in list.first { $0.id == id } }.filter { $0.account.id == s.id }
        for item in items { await move(item, to: box) }
        return !items.isEmpty
    }

    /// Conversations dropped on Inbox (or All inboxes): each goes to its own account's inbox.
    func dropOnInboxes(_ ids: [String]) async {
        for id in ids {
            guard let item = list.first(where: { $0.id == id }), let s = state(for: item.account), let inbox = s.box("inbox") else { continue }
            await move(item, to: inbox)
        }
    }

    // MARK: Opening and saving one email

    /// An email for its own window: from the list if it's there, otherwise fetched.
    func item(_ ref: MessageRef) async -> Item? {
        if let hit = list.first(where: { $0.account.id == ref.account && $0.email.id == ref.email }) { return hit }
        guard let s = state(id: ref.account), let e = try? await s.client.email(ref.email) else { return nil }
        return Item(account: s.account, email: e)
    }

    /// The email exactly as it arrived (an .eml file), to save or share.
    func original(_ email: Email, account: Account) async -> Data? {
        guard let s = state(for: account) else { return nil }
        do {
            var blob = email.blobId
            if blob == nil { blob = try await s.client.email(email.id)?.blobId }
            guard let blob else { throw JMAPError.missing("the original email") }
            return try await s.client.download(blobId: blob, type: "message/rfc822")
        } catch {
            problem = "Couldn't save the email: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Sending addresses

    /// The address new emails and forwards start from: the one chosen in Settings, else the account's first.
    func defaultIdentity(_ s: AccountState) -> Identity? {
        let chosen = UserDefaults.standard.string(forKey: "defaultFrom." + s.account.id)
        return s.identities.first { $0.id == chosen } ?? s.identities.first { !$0.isWildcard } ?? s.identities.first
    }

    func setDefaultIdentity(_ id: String, account: Account) {
        UserDefaults.standard.set(id, forKey: "defaultFrom." + account.id)
        objectWillChange.send()
    }

    func saveReplyTo(_ text: String, identity: Identity, account: Account) async -> Bool {
        guard let s = state(for: account) else { return false }
        do {
            try await s.client.setReplyTo(identityId: identity.id, to: EmailAddress.parse(text))
            s.identities = (try? await s.client.identities()) ?? s.identities
            objectWillChange.send()
            return true
        } catch {
            problem = "Couldn't save the reply to address: \(error.localizedDescription)"
            return false
        }
    }

    /// Adds an address to send from and returns it, or throws the server's reason for saying no.
    func addIdentity(_ email: String, account: Account) async throws -> Identity? {
        guard let s = state(for: account) else { return nil }
        let name = defaultIdentity(s)?.name ?? ""
        try await s.client.createIdentity(name: name, email: email)
        s.identities = (try? await s.client.identities()) ?? s.identities
        objectWillChange.send()
        return s.identities.first { $0.email.lowercased() == email.lowercased() }
    }

    // MARK: Signatures

    func signature(for identity: Identity) -> String {
        (identity.textSignature ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func saveSignature(_ text: String, identity: Identity, account: Account) async {
        guard let s = state(for: account) else { return }
        do {
            try await s.client.setSignature(identityId: identity.id, text: text)
            s.identities = (try? await s.client.identities()) ?? s.identities
            objectWillChange.send()
        } catch {
            problem = "Couldn't save the signature: \(error.localizedDescription)"
        }
    }

    /// Takes an item off the list and moves the selection to the next one down, the way a mail app should.
    private func takeOut(_ item: Item) {
        guard let i = list.firstIndex(where: { $0.id == item.id }) else { return }
        let wasSelected = selection == item.id
        list.remove(at: i)
        if wasSelected { selection = i < list.count ? list[i].id : list.last?.id }
    }

    /// Changes emails on screen straight away, before the server confirms.
    private func replace(account: Account, ids: Set<String>, _ change: (Email) -> Email) {
        list = list.map { $0.account.id == account.id && ids.contains($0.email.id) ? Item(account: account, email: change($0.email)) : $0 }
        if let s = state(for: account) { s.inbox = s.inbox.map { ids.contains($0.id) ? change($0) : $0 } }
    }

    private func act(_ s: AccountState, reloadList again: Bool = true, _ work: () async throws -> Void) async {
        do { try await work() } catch { problem = "\(s.account.label): \(error.localizedDescription)" }
        // Unread counts and folders come back from the server; the list itself was already changed on screen.
        if let boxes = try? await s.client.mailboxes() { s.mailboxes = boxes; objectWillChange.send() }
        if again { await reloadList(quietly: true) }
    }
}

enum AttachError: LocalizedError {
    case tooBig(String)
    var errorDescription: String? {
        switch self { case .tooBig(let name): return "\(name) is over 25 MB, too big to email." }
    }
}

extension Email {
    /// A copy with one keyword set or cleared.
    func with(keyword: String, on: Bool) -> Email {
        var k = keywords ?? [:]
        if on { k[keyword] = true } else { k.removeValue(forKey: keyword) }
        return Email(id: id, threadId: threadId, mailboxIds: mailboxIds, keywords: k, from: from, to: to, cc: cc,
                     replyTo: replyTo, subject: subject, preview: preview, receivedAt: receivedAt,
                     hasAttachment: hasAttachment, messageId: messageId, references: references, blobId: blobId,
                     bcc: bcc, inReplyTo: inReplyTo)
    }
}
