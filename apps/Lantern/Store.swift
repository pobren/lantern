// The app's state: the accounts and their folders, the list on screen, the open conversation, and every action
// (read, star, archive, move, delete, send). Lists can mix accounts; each item remembers where it came from.

import Foundation
import SwiftUI

/// An account the person added. Saved in settings; its token is in the Keychain.
struct Account: Codable, Identifiable, Hashable {
    let id: String
    let kind: String          // a ServerKind id ("fastmail", "stalwart", "other" and so on) or "demo" (sample mail)
    let sessionURL: String
    var username: String

    var saved: SavedKeys.Saved { SavedKeys.Saved(kind: kind, sessionURL: sessionURL, username: username) }
    /// Mail App, even if it was added under another provider by mistake: only Mail App serves JMAP at /api/ext/jmap.
    var isMailApp: Bool { kind == ServerKind.mailApp.id || sessionURL.contains("/api/ext/jmap/") }
    var colour: Color { kind == "fastmail" || kind == Demo.kind ? Look.fastmail : isMailApp ? Look.mailApp : Look.other }
    var kindName: String {
        if kind == Demo.kind { return "Sample mail" }
        if isMailApp { return ServerKind.mailApp.name }
        if kind == ServerKind.other.id { return "JMAP" }
        return ServerKind.named(kind)?.name ?? "JMAP"
    }
    var label: String {
        if kind == Demo.kind { return "Sample mail" }
        return username.isEmpty ? (kind == ServerKind.other.id ? "Mail" : kindName) : username
    }
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
    /// The address book (Fastmail contacts) plus people in the inbox, for filling in To, Cc and Bcc.
    @Published var contacts: [Contact] = []
    var contactsLoaded = false
    var id: String { account.id }

    func loadContacts() async {
        guard !contactsLoaded else { return }
        contactsLoaded = true
        var seen = Set<String>()
        var all: [Contact] = []
        let book = (try? await client.contactList()) ?? []
        let people = inbox.flatMap { ($0.from ?? []) + ($0.to ?? []) + ($0.cc ?? []) }.map { Contact(name: $0.name ?? "", email: $0.email) }
        for c in book + people where seen.insert(c.id).inserted { all.append(c) }
        contacts = all
    }

    init(account: Account, client: JMAPClient) {
        self.account = account
        self.client = client
    }

    func box(_ role: String) -> Mailbox? { mailboxes.first { $0.role == role } }
    /// Fastmail's Scheduled folder, where mail waits to send later.
    var scheduledBox: Mailbox? { box("scheduled") ?? mailboxes.first { $0.parentId == nil && $0.name == "Scheduled" } }
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

enum SearchScope: Hashable { case allMail, thisFolder }

@MainActor
final class Store: ObservableObject {
    @Published var accounts: [AccountState] = []
    @Published var problem: String?

    // The middle column.
    @Published var folder: Folder = .allInboxes
    @Published var list: [Item] = []
    @Published var listLoading = false
    @Published var search = ""
    /// Where a search looks: every folder (apart from Bin and Spam) in every account, or just the folder on screen.
    @Published var searchScope: SearchScope = .allMail
    var listLimit = 100
    @Published var mayHaveMore = false

    // The reading pane.
    @Published var selection: Item.ID?

    // Folders whose subfolders are tucked away in the sidebar, as "account/folder".
    @Published var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsed") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "collapsed") }
    }

    private var listeners: [String: Task<Void, Never>] = [:]

    // Mail kept on the device (Offline.swift does the filling and the catching up).
    let cache = MailCache.shared
    /// No connection to the server right now: lists, reading and search come from the device.
    @Published var offline = false
    /// Emails written offline, waiting to send.
    @Published var outbox = 0
    /// The folder last chosen from Move to, for Move again (⌥⌘T on the Mac, like Apple Mail).
    @Published var lastMove: (account: String, box: String)?
    /// Show only unread, starred or with attachments in the list (Apple Mail's filter button).
    @Published var listFilter: ListFilter = .all
    /// The smart folder open in the list, if any (its name shows as the list's title).
    @Published var smartFolder: SmartFolder?
    /// Select several emails: whether the list shows tick circles, and which are ticked.
    @Published var selecting = false
    @Published var picked: Set<Item.ID> = []
    var syncs: [String: Task<Void, Never>] = [:]
    var resync: Set<String> = []
    var flushing = false
    var network: NetworkWatch?
    private let savedKey = "accounts"

    init() {
        let data = UserDefaults.standard.data(forKey: savedKey)
        let saved = data.flatMap { try? JSONDecoder().decode([Account].self, from: $0) } ?? []
        for account in saved {
            guard let token = account.kind == Demo.kind ? "demo" : Keychain.read(account.id),
                  let url = URL(string: account.sessionURL) else { continue }
            accounts.append(AccountState(account: account, client: JMAPClient(sessionURL: url, token: token)))
        }
        if Demo.launchedForScreens && !hasDemo && !Demo.welcomeShot { accounts.append(Self.demoState()) }
        if Demo.launchedForScreens { NSLog("JCDEBUG store ready, %d accounts", accounts.count) }
    }

    private static func demoState() -> AccountState {
        AccountState(account: Account(id: "sample-mail", kind: Demo.kind, sessionURL: Demo.sessionURL, username: Demo.me.email),
                     client: JMAPClient(sessionURL: URL(string: Demo.sessionURL)!, token: "demo"))
    }

    var hasAccounts: Bool { !accounts.isEmpty }
    var hasDemo: Bool { accounts.contains { $0.account.kind == Demo.kind } }
    func state(for account: Account) -> AccountState? { accounts.first { $0.id == account.id } }
    func state(id: String) -> AccountState? { accounts.first { $0.id == id } }
    var selectedItem: Item? { list.first { $0.id == selection } }

    // MARK: Accounts

    func add(kind: ServerKind, address: String, token: String) async throws {
        try await add(kind: kind, sessions: [Self.sessionAddress(address.isEmpty ? kind.sessionURL : address)],
                      secret: token.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Adds a Fastmail account after "Sign in with Fastmail" (OAuth). `secret` is "oauth:<key id>" from FastmailOAuth.
    func addSignedIn(secret: String) async throws {
        do {
            try await add(kind: .fastmail, sessions: [FastmailOAuth.sessionURL], secret: secret)
        } catch {
            await FastmailOAuth.signOut(secret)
            throw error
        }
    }

    /// Adds an account that signs in with an email address and app password (Stalwart, Thundermail, Mailbux, Cyrus
    /// and other JMAP servers). With no server given, it's found from the email address's domain. With no email
    /// address, the password is used as an API token, for servers that hand those out instead.
    func add(kind: ServerKind, email: String, password: String, server: String) async throws {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password.trimmingCharacters(in: .newlines)
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = email.isEmpty ? password.trimmingCharacters(in: .whitespaces) : JMAPAuth.basic(user: email, password: password)
        var sessions: [String] = []
        if !server.isEmpty {
            if kind.id == ServerKind.mailApp.id { sessions.append(Self.mailAppSession(server)) }
            else {
                sessions.append(Self.sessionAddress(server))
                // Mail App picked by mistake as another provider: its JMAP isn't at /.well-known/jmap, so try its own address too.
                if !server.contains("/jmap") && !server.contains("well-known") { sessions.append(Self.mailAppSession(server)) }
            }
        }
        else if !kind.sessionURL.isEmpty { sessions.append(kind.sessionURL) }
        else if let domain = email.split(separator: "@").last.map(String.init)?.lowercased(), email.contains("@"), domain.contains(".") {
            sessions = ["https://\(domain)/.well-known/jmap", "https://mail.\(domain)/.well-known/jmap", "https://jmap.\(domain)/.well-known/jmap"]
        }
        guard !sessions.isEmpty else { throw JMAPError.needServer }
        try await add(kind: kind, sessions: sessions, secret: secret, typedEmail: email)
    }

    /// Tries each possible session address in turn. A wrong password stops at once: the server was found.
    private func add(kind: ServerKind, sessions: [String], secret: String, typedEmail: String = "") async throws {
        var lastError: Error = JMAPError.badServer
        for session in sessions {
            guard let url = URL(string: session) else { continue }
            let client = JMAPClient(sessionURL: url, token: secret)
            let s: JMAPSession
            do { s = try await client.connect() }
            catch JMAPError.signIn { throw JMAPError.signIn }
            catch { lastError = error; continue }
            let found = client.finalSessionURL?.absoluteString ?? session
            let account = Account(id: UUID().uuidString, kind: found.contains("/api/ext/jmap/") ? ServerKind.mailApp.id : kind.id, sessionURL: found,
                                  username: Self.accountName(server: s.username, typed: typedEmail))
            Keychain.save(account.id, secret)
            // A Fastmail sign in belongs to this device only (Fastmail's rule), so it never goes to iCloud Keychain.
            if !FastmailOAuth.isOAuth(secret) { SavedKeys.save(account.saved, token: secret) }
            let state = AccountState(account: account, client: client)
            accounts.append(state)
            save()
            await load(state)
            listen(state)
            keepSynced(state)
            await reloadList()
            return
        }
        throw sessions.count > 1 ? JMAPError.notFound : lastError
    }

    /// Mail App keeps JMAP under /api/ext/jmap, the only part of it Cloudflare Access lets apps reach, so its
    /// /.well-known/jmap can't be used: mail.example.com becomes https://mail.example.com/api/ext/jmap/session.
    static func mailAppSession(_ typed: String) -> String {
        var session = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !session.hasPrefix("http") { session = "https://" + session }
        if session.contains("/api/ext/jmap") { return session }
        guard let url = URL(string: session), let host = url.host else { return session }
        return "https://\(host)\(url.port.map { ":\($0)" } ?? "")/api/ext/jmap/session"
    }

    /// The name an account is shown by. Some servers give a key's name (Mail App's keys are often all called
    /// "JMAP Connect"), so when that isn't an email address the address the person typed is used instead.
    static func accountName(server: String, typed: String) -> String {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return !server.contains("@") && typed.contains("@") ? typed : server
    }

    /// Turns what someone typed (mail.example.com, a full https address) into a JMAP session address.
    static func sessionAddress(_ typed: String) -> String {
        var session = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !session.hasPrefix("http") { session = "https://" + session }
        if !session.contains("/jmap") && !session.contains("well-known") {
            session = session.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/.well-known/jmap"
        }
        return session
    }

    /// Adds the sample mail account: made up emails answered inside the app, for trying it without an account.
    func addDemo() async {
        guard !hasDemo else { return }
        let state = Self.demoState()
        accounts.append(state)
        save()
        await load(state)
        await reloadList()
    }

    /// Saved keys (iCloud Keychain) for accounts that aren't added on this device, so they can come back in one tap.
    func savedKeys(kind: ServerKind) -> [SavedKeys.Saved] { savedKeys(kinds: [kind]) }

    func savedKeys(kinds: [ServerKind]) -> [SavedKeys.Saved] {
        let here = Set(accounts.map(\.account.saved.id))
        let ids = Set(kinds.map(\.id))
        return SavedKeys.all().filter { ids.contains($0.kind) && !here.contains($0.id) }.sorted { $0.username < $1.username }
    }

    /// Signs back in with a saved key. If Fastmail no longer accepts it (deleted on the website), it's forgotten.
    func add(saved: SavedKeys.Saved) async throws {
        guard let token = SavedKeys.token(saved), let kind = ServerKind.named(saved.kind) else {
            throw JMAPError.missing("the saved key")
        }
        do {
            try await add(kind: kind, address: saved.sessionURL, token: token)
        } catch JMAPError.signIn {
            SavedKeys.delete(saved)
            throw JMAPError.missing("a working key: it was deleted in \(kind.name), so make a new one")
        }
    }

    func remove(_ state: AccountState, forgetKey: Bool = false) {
        if forgetKey { SavedKeys.delete(state.account.saved) }
        listeners[state.id]?.cancel()
        listeners[state.id] = nil
        syncs[state.id]?.cancel()
        syncs[state.id] = nil
        let gone = state.id
        Task { await cache.clear(account: gone, keepPending: false); await countOutbox() }
        if let secret = Keychain.read(state.id), FastmailOAuth.isOAuth(secret) {
            // Instant alerts are stopped first, while the sign in still works; then Fastmail is told we're done.
            Task {
                #if os(iOS)
                await InstantAlerts.shared.forget(gone)
                #endif
                await FastmailOAuth.signOut(secret)
            }
        }
        Keychain.delete(state.id)
        accounts.removeAll { $0.id == state.id }
        if case .mailbox(let account, _) = folder, account == state.id { folder = .allInboxes }
        save()
        Task { await reloadList() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts.map(\.account)) { UserDefaults.standard.set(data, forKey: savedKey) }
        #if os(iOS)
        WatchLink.shared.start(self)
        #endif
    }

    // MARK: Loading

    func start() async {
        await loadSaved()
        watchNetwork()
        await refresh()
        for state in accounts { listen(state) }
        for state in accounts { keepSynced(state) }
    }

    func refresh() async {
        await withTaskGroup(of: Void.self) { group in
            for state in accounts { group.addTask { await self.load(state) } }
        }
        await reloadList()
        saveWidget()
    }

    /// Folders, addresses and the inbox for one account.
    private func load(_ state: AccountState) async {
        do {
            if state.client.session == nil { try await state.client.connect() }
            state.mailboxes = try await state.client.mailboxes()
            if let scheduled = state.scheduledBox, let sent = state.box("sent"), !isSample(state) {
                try? await state.client.releaseScheduled(scheduled: scheduled.id, sent: sent.id)
            }
            if state.identities.isEmpty { state.identities = (try? await state.client.identities()) ?? [] }
            if let inbox = state.box("inbox") {
                state.inbox = try await state.client.emails(filter: ["inMailbox": inbox.id], limit: 100)
                Notifier.newMail(in: state.inbox, account: state.account)
            }
            problem = nil
            backOnline()
            await remember(state)
        } catch {
            report(state, error)
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
        keepSynced(state)
        switch folder {
        case .allInboxes: await reloadList(quietly: true)
        case .mailbox(let account, _) where account == id: await reloadList(quietly: true)
        default: break
        }
    }

    // MARK: The list

    func open(_ f: Folder) async {
        // Leaving a smart folder: its search goes too.
        if let smart = smartFolder {
            smartFolder = nil
            if search.trimmingCharacters(in: .whitespaces) == smart.search { search = "" }
        }
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
    /// Mail saved on the device shows first when the list is empty (opening a folder, a new search, starting up,
    /// or offline), then the server's answer replaces it.
    func reloadList(quietly: Bool = false) async {
        let words = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = folder
        let scope = searchScope
        let only = listFilter
        func current() -> Bool {
            wanted == folder && scope == searchScope && only == listFilter && words == search.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        /// The list filter (unread, starred, attachments) on top of the folder or search.
        func narrowed(_ f: [String: Any]) -> [String: Any] {
            guard let c = only.condition else { return f }
            return ["operator": "AND", "conditions": [f, c]]
        }
        if list.isEmpty || offline {
            let saved = await savedItems(words: words, folder: wanted, scope: scope, limit: listLimit).filter { only.matches($0.email) }
            if current() && (!saved.isEmpty || offline) {
                list = saved
                mayHaveMore = saved.count >= listLimit
            }
        }
        if !quietly && list.isEmpty { listLoading = true }
        defer { listLoading = false }
        var items: [Item] = []
        var reached = false
        let query = SearchQuery(words)
        if !words.isEmpty && scope == .allMail {
            for s in shownAccounts {
                let skip = [s.box("trash")?.id, s.box("junk")?.id].compactMap { $0 }
                let base: [String: Any] = skip.isEmpty ? [:] : ["inMailboxOtherThan": skip]
                let filter = narrowed(query.filter(adding: base))
                do {
                    items += try await s.client.emails(filter: filter, limit: listLimit).map { Item(account: s.account, email: $0) }
                    reached = true
                } catch { report(s, error) }
            }
        } else {
            switch wanted {
            case .allInboxes:
                if words.isEmpty && listLimit <= 100 && only == .all {
                    items = shownAccounts.flatMap { s in s.inbox.map { Item(account: s.account, email: $0) } }
                    reached = !offline
                } else {
                    for s in shownAccounts {
                        guard let inbox = s.box("inbox") else { continue }
                        let filter = narrowed(words.isEmpty ? ["inMailbox": inbox.id] : query.filter(adding: ["inMailbox": inbox.id]))
                        do {
                            items += try await s.client.emails(filter: filter, limit: listLimit).map { Item(account: s.account, email: $0) }
                            reached = true
                        } catch { report(s, error) }
                    }
                }
            case .mailbox(let accountId, let boxId):
                guard let s = state(id: accountId) else { break }
                let filter = narrowed(words.isEmpty ? ["inMailbox": boxId] : query.filter(adding: ["inMailbox": boxId]))
                do {
                    items = try await s.client.emails(filter: filter, limit: listLimit).map { Item(account: s.account, email: $0) }
                    reached = true
                } catch { report(s, error) }
            }
        }
        guard current() else { return }  // the person moved on while this was loading
        guard reached else { return }     // offline: the saved list stays on screen
        backOnline()
        list = items.filter { only.matches($0.email) }.sorted { $0.email.date > $1.email.date }
        mayHaveMore = items.count >= listLimit
        await remember(items)
    }

    /// Searches saved mail as you type, before anything goes to the server.
    func searchSaved() async {
        let words = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        // from:, to: and the like: saved mail can't answer those, so ask the server straight away.
        if SearchQuery(words).narrowed { await reloadList(); return }
        let found = await savedItems(words: words, folder: folder, scope: searchScope, limit: listLimit).filter { listFilter.matches($0.email) }
        // Nothing saved yet (a new account, or sample mail): leave the list for the server's search.
        guard !found.isEmpty, words == search.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        list = found
        mayHaveMore = false
    }

    /// The middle column from mail saved on the device.
    func savedItems(words: String, folder wanted: Folder, scope: SearchScope, limit: Int) async -> [Item] {
        var items: [Item] = []
        for s in accounts where !isSample(s) {
            let id = s.id
            let skip = [s.box("trash")?.id, s.box("junk")?.id].compactMap { $0 }
            var box: String?
            switch wanted {
            case .allInboxes: box = s.box("inbox")?.id
            case .mailbox(let a, let b): box = a == id ? b : nil
            }
            if words.isEmpty {
                guard let box else { continue }
                items += await cache.list(box: box, account: id, limit: limit).map { Item(account: s.account, email: $0) }
            } else if scope == .allMail {
                items += await cache.search(words, account: id, box: nil, skip: skip, limit: limit).map { Item(account: s.account, email: $0) }
            } else if let box {
                items += await cache.search(words, account: id, box: box, skip: [], limit: limit).map { Item(account: s.account, email: $0) }
            }
        }
        return Array(items.sorted { $0.email.date > $1.email.date }.prefix(limit))
    }

    var folderTitle: String {
        switch folder {
        case .allInboxes: return accounts.count > 1 ? "All inboxes" : "Inbox"
        case .mailbox(let a, let id): return state(id: a)?.box(id: id)?.name ?? "Mail"
        }
    }

    /// True while the list shows results from every folder, rather than the folder in the sidebar.
    var searchingAllMail: Bool {
        searchScope == .allMail && !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The middle column's title: the folder, or "All mail" while searching everywhere.
    var listTitle: String {
        if let f = smartFolder, f.search == search.trimmingCharacters(in: .whitespaces) { return f.name }
        return searchingAllMail ? "All mail" : folderTitle
    }

    /// The folder an email lives in, shown on search results from every folder.
    func place(of item: Item) -> String? {
        guard let s = state(for: item.account) else { return nil }
        return source(for: item, in: s)?.name
    }

    /// Unread across every inbox, for the sidebar and the Dock.
    var unreadInboxes: Int {
        shownAccounts.reduce(0) { $0 + ($1.box("inbox")?.unreadEmails ?? 0) }
    }

    /// The folder an item is being looked at in, so archive and move know where to take it from.
    /// Search results from every folder come from wherever the email actually lives: the folder on screen if it's
    /// there, then the Inbox, then any other folder or label it's in.
    private func source(for item: Item, in s: AccountState) -> Mailbox? {
        let everywhere = searchingAllMail
        if case .mailbox(let a, let id) = folder, a == s.id, !everywhere || item.email.mailboxIds[id] == true { return s.box(id: id) }
        guard everywhere else { return s.box("inbox") }
        let ids = Set(item.email.mailboxIds.filter(\.value).keys)
        if let inbox = s.box("inbox"), ids.contains(inbox.id) { return inbox }
        return s.mailboxes.first { ids.contains($0.id) } ?? s.box("inbox")
    }

    // MARK: Reading

    private var pages: [String: (html: String, attachments: [Attachment])] = [:]
    func clearPages() { pages = [:] }

    func conversation(_ item: Item) async -> [Email] {
        guard let s = state(for: item.account) else { return [item.email] }
        var all: [Email]
        do {
            all = try await s.client.thread(item.email.threadId)
            await remember(all, in: s)
        } catch {
            report(s, error, quietly: true)
            all = isSample(s) ? [] : await cache.thread(item.email.threadId, account: s.id)
            if all.isEmpty { all = [item.email] }
        }
        // Keep drafts and anything in the bin out of a conversation, unless that's where you're looking.
        let trash = s.box("trash")?.id
        let lookingInTrash = source(for: item, in: s)?.role == "trash"
        let shown = all.filter { e in !e.isDraft && (lookingInTrash || trash == nil || e.mailboxIds.keys.contains { $0 != trash }) }
        return shown.isEmpty ? [item.email] : shown
    }

    /// The email laid out as its sender designed it, plus its attachments.
    /// How to leave the mailing list an email came from, if it says. Nothing while offline or for sample mail.
    /// When this email is waiting to send later, the pending send.
    func waiting(_ email: Email, account: Account) async -> Waiting? {
        guard let s = state(for: account), !isSample(s), !offline else { return nil }
        let held = email.mailboxIds.keys.contains { $0 == s.scheduledBox?.id || $0 == s.box("sent")?.id }
        guard held else { return nil }
        return try? await s.client.waiting(email.id)
    }

    /// Stops a scheduled email and puts it back in Drafts.
    func cancelScheduled(_ email: Email, waiting: Waiting, account: Account) async -> Bool {
        guard let s = state(for: account), let drafts = s.box("drafts") else { return false }
        do {
            try await s.client.cancelScheduled(email.id, waiting: waiting, scheduled: s.scheduledBox?.id, drafts: drafts.id)
            await refresh()
            return true
        } catch {
            report(s, error)
            return false
        }
    }

    func unsubscribe(_ email: Email, account: Account) async -> Unsubscribe? {
        guard let s = state(for: account), !isSample(s), !offline else { return nil }
        let u = try? await s.client.unsubscribe(for: email.id)
        return u?.any == true ? u : nil
    }

    func page(_ email: Email, account: Account) async -> (html: String, attachments: [Attachment])? {
        let key = account.id + "/" + email.id
        if let cached = pages[key] { return cached }
        guard let s = state(for: account) else { return nil }
        let saved = isSample(s) ? nil : await cache.page(email.id, account: account.id)
        if let saved, saved.complete {
            pages[key] = (saved.html, saved.attachments)
            return pages[key]
        }
        do {
            let page = try await s.client.page(of: email.id)
            pages[key] = page
            if !isSample(s) {
                let text = saved?.text ?? JMAPClient.plain(page.html)
                await cache.savePage(SavedPage(html: page.html, text: text, attachments: page.attachments, complete: true),
                                     id: email.id, account: account.id)
            }
            return page
        } catch {
            report(s, error, quietly: true)
            guard let saved else { return nil }
            return (saved.html, saved.attachments)
        }
    }

    func text(_ email: Email, account: Account) async -> String {
        guard let s = state(for: account) else { return email.preview ?? "" }
        do { return try await s.client.body(of: email.id) } catch {
            report(s, error, quietly: true)
            if let saved = await cache.page(email.id, account: account.id), !saved.text.isEmpty { return saved.text }
            return email.preview ?? ""
        }
    }

    /// Saves an attachment to a temporary file, ready to preview or share.
    func file(_ a: Attachment, account: Account) async -> URL? {
        guard let s = state(for: account) else { return nil }
        // Kept with the saved mail, so an attachment opened once opens again offline.
        let folder = MailCache.files.appendingPathComponent(account.id, isDirectory: true).appendingPathComponent(a.blobId, isDirectory: true)
        let safe = a.name.replacingOccurrences(of: "/", with: "-")
        let url = folder.appendingPathComponent(safe.isEmpty ? "Attachment" : safe)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            let data = try await s.client.download(blobId: a.blobId, type: a.type)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        } catch {
            if Self.isOffline(error) { goOffline(); problem = "\(a.name) hasn't been opened before, so it needs a connection." }
            else { problem = "Couldn't open \(a.name): \(error.localizedDescription)" }
            return nil
        }
    }

    // MARK: Actions

    func markRead(_ emails: [Email], account: Account) async {
        let ids = emails.filter(\.isUnread).map(\.id)
        guard !ids.isEmpty, let s = state(for: account) else { return }
        replace(account: account, ids: Set(ids)) { $0.with(keyword: "$seen", on: true) }
        await apply(Dictionary(uniqueKeysWithValues: ids.map { ($0, ["keywords/$seen": true] as [String: Any]) }), in: s)
    }

    func setUnread(_ item: Item, _ unread: Bool) async {
        guard let s = state(for: item.account) else { return }
        replace(account: item.account, ids: [item.email.id]) { $0.with(keyword: "$seen", on: !unread) }
        await apply([item.email.id: ["keywords/$seen": unread ? NSNull() as Any : true as Any]], in: s)
    }

    func flag(_ item: Item) async {
        guard let s = state(for: item.account) else { return }
        let on = !item.email.isFlagged
        replace(account: item.account, ids: [item.email.id]) { $0.with(keyword: "$flagged", on: on) }
        await apply([item.email.id: ["keywords/$flagged": on ? true as Any : NSNull() as Any]], in: s)
    }

    /// Mute (Paul, 20 Nov 2026, after Fastmail's): marks every email in the conversation $muted, the keyword
    /// Fastmail uses, so later replies skip the inbox; muting also archives it. Unmute takes the mark off again.
    func mute(_ item: Item, _ on: Bool) async {
        guard let s = state(for: item.account) else { return }
        var thread = (try? await s.client.thread(item.email.threadId)) ?? []
        if thread.isEmpty { thread = [item.email] }
        let ids = Set(thread.map(\.id))
        replace(account: item.account, ids: ids) { $0.with(keyword: "$muted", on: on) }
        await apply(Dictionary(uniqueKeysWithValues: ids.map { ($0, ["keywords/$muted": on ? true as Any : NSNull() as Any] as [String: Any]) }), in: s)
        if on, let inbox = s.box("inbox"), source(for: item, in: s)?.id == inbox.id { await archive(item) }
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
        var thread: [Email]
        do { thread = try await s.client.thread(item.email.threadId) } catch {
            report(s, error, quietly: true)
            thread = isSample(s) ? [] : await cache.thread(item.email.threadId, account: s.id)
            if thread.isEmpty { thread = [item.email] }
        }
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
        // Undo (⌘Z) puts every email back in the mailboxes it was in, with the spam marks as they were.
        var restore: [String: [String: Any]] = [:]
        for e in emails {
            var back: [String: Any] = ["mailboxIds": e.mailboxIds.filter(\.value)]
            for key in extra.keys where key.hasPrefix("keywords/") {
                let name = String(key.dropFirst("keywords/".count))
                back[key] = e.keywords?[name] == true ? true as Any : NSNull() as Any
            }
            restore[e.id] = back
        }
        let done: String
        switch target.role {
        case "trash": done = "Deleted"
        case "archive": done = "Archived"
        case "junk": done = "Marked as spam"
        default: done = from.role == "junk" && target.role == "inbox" ? "Moved to Inbox" : "Moved to \(target.name)"
        }
        UndoMove.shared.offer(UndoMove.Done(title: done, account: item.account, patches: restore))
        // Move again repeats a move you chose from Move to (not Archive, Delete or Spam).
        if extra.isEmpty && !keepLabels && !exclusive && target.role != "archive" {
            lastMove = (account: s.id, box: target.id)
        }
        takeOut(item)
        if from.role == "inbox" || exclusive { s.inbox.removeAll { $0.threadId == item.email.threadId } }
        await apply(patches, in: s)
    }

    /// Adds or takes off a label (Fastmail mailbox) on the whole conversation, keeping its other labels.
    /// An email has to stay somewhere, so the last label can't come off (archive it instead).
    func setLabel(_ item: Item, _ box: Mailbox, on: Bool) async {
        guard let s = state(for: item.account) else { return }
        var thread = (try? await s.client.thread(item.email.threadId)) ?? []
        if thread.isEmpty { thread = [item.email] }
        var patches: [String: [String: Any]] = [:]
        for e in thread {
            if on, e.mailboxIds[box.id] != true { patches[e.id] = ["mailboxIds/\(box.id)": true] }
            if !on, e.mailboxIds[box.id] == true {
                guard e.mailboxIds.keys.contains(where: { $0 != box.id }) else {
                    problem = "That's the only label on this email. Archive or move it instead."
                    return
                }
                patches[e.id] = ["mailboxIds/\(box.id)": NSNull()]
            }
        }
        await apply(patches, in: s)
        await reloadList(quietly: true)
    }

    /// The labels an email can take: every folder except Bin, Spam, Drafts and Sent.
    /// Settings key: show the Labels menu. Off by default, because Fastmail uses folders unless you switch to labels
    /// in its own settings, and JMAP doesn't tell apps which (Paul uses folders, 20 Nov 2026).
    static let labelsKey = "showLabels"
    var showsLabels: Bool { UserDefaults.standard.bool(forKey: Self.labelsKey) }

    func labels(for item: Item) -> [FolderEntry] {
        guard let s = state(for: item.account) else { return [] }
        return s.tree.filter { !["trash", "junk", "drafts", "sent"].contains($0.box.role ?? "") }
    }

    /// The In-Reply-To and References headers for an answer to this email.
    nonisolated static func threading(_ replyTo: Email?) -> (inReplyTo: String?, references: [String]) {
        (replyTo?.messageId?.first, replyTo?.references ?? [])
    }

    func send(account: Account, identity: Identity, as address: String? = nil, to: [EmailAddress], cc: [EmailAddress], bcc: [EmailAddress] = [], subject: String, text: String,
              threading: (inReplyTo: String?, references: [String]), attachments: [Outgoing] = [], replacing: String? = nil,
              sendAt: Date? = nil, undoDraft: ComposeDraft? = nil) async throws {
        guard let s = state(for: account), let drafts = s.box("drafts"), let sent = s.box("sent") else { throw JMAPError.missing("Drafts or Sent") }
        do {
            let hold = sendAt == nil && !isSample(s) ? UndoSend.seconds : 0
            let sentEmail = try await s.client.send(from: identity, as: address, to: to, cc: cc, bcc: bcc, subject: subject, text: text,
                                    inReplyTo: threading.inReplyTo, references: threading.references,
                                    attachments: attachments, drafts: drafts.id, sent: sent.id, scheduled: s.scheduledBox?.id,
                                    replacing: replacing, sendAt: sendAt, holdFor: hold)
            if hold > 0, let sentEmail, sentEmail.heldUntil != nil, let draft = undoDraft {
                offerUndo(sentEmail, account: account, draft: draft)
            }
        } catch let error where Self.isOffline(error) && !isSample(s) && sendAt == nil {
            // No connection: it waits in the Outbox and sends itself when the connection is back.
            goOffline()
            let mail = OutboxEmail(identityId: identity.id, address: address, to: to, cc: cc, bcc: bcc, subject: subject, text: text,
                                   inReplyTo: threading.inReplyTo, references: threading.references,
                                   attachments: attachments.map { OutgoingFile(blobId: $0.blobId, name: $0.name, type: $0.type, size: $0.size) },
                                   replacing: replacing)
            await cache.queue(Pending(account: s.id, kind: "send", data: try JSONEncoder().encode(mail)))
            await countOutbox()
            return
        }
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

    /// Opens an email from a tapped alert: every inbox on screen, with that email selected.
    func show(_ ref: MessageRef) async {
        if search.isEmpty == false { search = "" }
        if folder != .allInboxes { await open(.allInboxes) } else if list.isEmpty { await reloadList() }
        guard let item = await item(ref) else { return }
        if !list.contains(where: { $0.id == item.id }) { list.insert(item, at: 0) }
        selection = item.id
    }

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
        do { try await work() } catch {
            if Self.isOffline(error) { goOffline(); problem = "You're offline. Try that again once you're connected." }
            else { report(s, error) }
        }
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
