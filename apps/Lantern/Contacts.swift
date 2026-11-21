// Contacts page (Paul, 20 Nov 2026), after Fastmail's own: browse and search the address book (personal and shared),
// open a card with someone's details and your recent emails with them, tap to email or call, keep a private note,
// and add, change or delete contacts. All saved in the mail account (JMAP Contacts, RFC 9610; cards are JSContact,
// RFC 9553), so it matches Fastmail on the web and every other device. No calendar, no clever views.

import SwiftUI

// MARK: The data

struct ContactEntry: Hashable, Identifiable {
    let id = UUID()         // for the lists on screen
    var serverId: String    // its key on the card, or "" until it's saved
    var value: String
    var label: String       // home, work, mobile and so on; empty if none
}

struct ContactCardData: Identifiable, Hashable {
    var id: String
    var account: String     // the app's account id
    var book: String        // the address book it's in
    var given = ""
    var surname = ""
    var full = ""
    var company = ""
    var jobTitle = ""
    var emails: [ContactEntry] = []
    var phones: [ContactEntry] = []
    var addresses: [String] = []
    var note = ""
    var noteId = "n1"

    var name: String {
        let joined = [given, surname].filter { !$0.isEmpty }.joined(separator: " ")
        if !joined.isEmpty { return joined }
        if !full.isEmpty { return full }
        if !company.isEmpty { return company }
        return emails.first?.value ?? "No name"
    }
    var sortKey: String { (surname.isEmpty ? name : surname + " " + given).lowercased() }
    var letter: String {
        let c = sortKey.first.map { String($0).uppercased() } ?? "#"
        return c.rangeOfCharacter(from: .letters) == nil ? "#" : c
    }
    var avatar: EmailAddress { EmailAddress(name: name, email: emails.first?.value ?? name) }

    func matches(_ words: String) -> Bool {
        let hay = ([name, company, jobTitle, note] + emails.map(\.value) + phones.map(\.value)).joined(separator: " ").lowercased()
        return words.lowercased().split(separator: " ").allSatisfy { hay.contains($0) }
    }
}

struct AddressBookInfo: Hashable, Identifiable {
    let id: String
    let name: String
    let isDefault: Bool
    let shared: Bool
}

extension JMAPClient {
    private var contactsAccount: String? { session?.primaryAccounts[Self.contacts] }

    func addressBooks() async throws -> [AddressBookInfo] {
        if session == nil { try await connect() }
        guard let acc = contactsAccount else { return [] }
        let r = try await call([["AddressBook/get", ["accountId": acc], "b"]], using: [Self.core, Self.contacts])
        return ((r["b"]?["list"] as? [[String: Any]]) ?? []).compactMap { b in
            guard let id = b["id"] as? String else { return nil }
            let shared = !(((b["shareWith"] as? [String: Any]) ?? [:]).isEmpty)
            return AddressBookInfo(id: id, name: b["name"] as? String ?? "Contacts", isDefault: b["isDefault"] as? Bool ?? false, shared: shared)
        }
    }

    /// Every person in every address book (groups are left out).
    func cards(account: String) async throws -> [ContactCardData] {
        if session == nil { try await connect() }
        guard let acc = contactsAccount else { return [] }
        let r = try await call([["ContactCard/get", ["accountId": acc], "c"]], using: [Self.core, Self.contacts])
        return ((r["c"]?["list"] as? [[String: Any]]) ?? []).compactMap { Self.card($0, account: account) }
    }

    static func card(_ c: [String: Any], account: String) -> ContactCardData? {
        guard let id = c["id"] as? String else { return nil }
        if let kind = c["kind"] as? String, kind == "group" { return nil }
        var out = ContactCardData(id: id, account: account, book: ((c["addressBookIds"] as? [String: Any]) ?? [:]).keys.sorted().first ?? "")
        let n = c["name"] as? [String: Any]
        out.full = n?["full"] as? String ?? ""
        for part in (n?["components"] as? [[String: Any]]) ?? [] {
            let v = part["value"] as? String ?? ""
            switch part["kind"] as? String {
            case "given": out.given = out.given.isEmpty ? v : out.given + " " + v
            case "surname": out.surname = out.surname.isEmpty ? v : out.surname + " " + v
            default: break
            }
        }
        out.company = ((c["organizations"] as? [String: Any])?.values.first as? [String: Any])?["name"] as? String ?? ""
        out.jobTitle = ((c["titles"] as? [String: Any])?.values.first as? [String: Any])?["name"] as? String ?? ""
        out.emails = entries(c["emails"], value: "address")
        out.phones = entries(c["phones"], value: "number")
        for (_, a) in ((c["addresses"] as? [String: Any]) ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let a = a as? [String: Any] else { continue }
            if let full = a["full"] as? String, !full.isEmpty { out.addresses.append(full); continue }
            let parts = ((a["components"] as? [[String: Any]]) ?? []).filter { $0["kind"] as? String != "separator" }
                .compactMap { $0["value"] as? String }.filter { !$0.isEmpty }
            if !parts.isEmpty { out.addresses.append(parts.joined(separator: ", ")) }
        }
        if let (key, note) = ((c["notes"] as? [String: Any]) ?? [:]).sorted(by: { $0.key < $1.key }).first,
           let text = (note as? [String: Any])?["note"] as? String {
            out.note = text
            out.noteId = key
        }
        return out
    }

    private static func entries(_ raw: Any?, value: String) -> [ContactEntry] {
        ((raw as? [String: Any]) ?? [:]).sorted { $0.key < $1.key }.compactMap { key, any in
            guard let e = any as? [String: Any], let v = e[value] as? String, !v.isEmpty else { return nil }
            var label = e["label"] as? String ?? ""
            if label.isEmpty {
                let contexts = ((e["contexts"] as? [String: Any]) ?? [:]).keys
                let features = ((e["features"] as? [String: Any]) ?? [:]).keys
                label = features.contains("mobile") ? "mobile" : contexts.contains("work") ? "work" : contexts.contains("private") ? "home" : ""
            }
            return ContactEntry(serverId: key, value: v, label: label)
        }
    }

    /// The JSContact properties this page edits. Other properties on the card are left alone.
    private static func patch(_ c: ContactCardData) -> [String: Any] {
        func map(_ list: [ContactEntry], _ key: String, extra: (ContactEntry) -> [String: Any]) -> [String: Any] {
            var out: [String: Any] = [:]
            for (i, e) in list.enumerated() where !e.value.trimmingCharacters(in: .whitespaces).isEmpty {
                var v: [String: Any] = [key: e.value.trimmingCharacters(in: .whitespaces)]
                v.merge(extra(e)) { a, _ in a }
                out[e.serverId.isEmpty ? "\(key.prefix(1))\(i + 1)-\(UUID().uuidString.prefix(6))" : e.serverId] = v
            }
            return out
        }
        func context(_ label: String) -> [String: Any] {
            switch label.lowercased() {
            case "work": return ["contexts": ["work": true]]
            case "home": return ["contexts": ["private": true]]
            default: return label.isEmpty ? [:] : ["label": label]
            }
        }
        var name: [String: Any] = ["components": [
            ["kind": "given", "value": c.given.trimmingCharacters(in: .whitespaces)],
            ["kind": "surname", "value": c.surname.trimmingCharacters(in: .whitespaces)],
        ].filter { !(($0["value"] as? String) ?? "").isEmpty }]
        let full = [c.given, c.surname].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { name["full"] = full; name["isOrdered"] = true }
        return [
            "name": name,
            "organizations": c.company.isEmpty ? NSNull() : ["o1": ["name": c.company]],
            "titles": c.jobTitle.isEmpty ? NSNull() : ["t1": ["name": c.jobTitle]],
            "emails": map(c.emails, "address") { context($0.label) },
            "phones": map(c.phones, "number") { e in
                var v = context(e.label == "mobile" ? "" : e.label)
                v["features"] = e.label == "mobile" ? ["mobile": true] : ["voice": true]
                return v
            },
            "notes": c.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSNull() : [c.noteId: ["note": c.note]],
        ]
    }

    /// Saves a card: changes an existing one, or makes a new one in its address book. Returns the card's id.
    func save(_ c: ContactCardData) async throws -> String {
        if session == nil { try await connect() }
        guard let acc = contactsAccount else { throw JMAPError.missing("an address book") }
        var fields = Self.patch(c)
        if c.id.isEmpty {
            fields = fields.filter { !($0.value is NSNull) }
            fields["@type"] = "Card"
            fields["version"] = "1.0"
            fields["kind"] = "individual"
            fields["addressBookIds"] = [c.book: true]
            let r = try await call([["ContactCard/set", ["accountId": acc, "create": ["new": fields]], "s"]], using: [Self.core, Self.contacts])
            if let why = (r["s"]?["notCreated"] as? [String: Any])?["new"] as? [String: Any] {
                throw JMAPError.method(why["type"] as? String ?? "notCreated", why["description"] as? String ?? "")
            }
            return ((r["s"]?["created"] as? [String: Any])?["new"] as? [String: Any])?["id"] as? String ?? ""
        }
        let r = try await call([["ContactCard/set", ["accountId": acc, "update": [c.id: fields]], "s"]], using: [Self.core, Self.contacts])
        if let why = (r["s"]?["notUpdated"] as? [String: Any])?[c.id] as? [String: Any] {
            throw JMAPError.method(why["type"] as? String ?? "notUpdated", why["description"] as? String ?? "")
        }
        return c.id
    }

    func deleteCard(_ id: String) async throws {
        guard let acc = contactsAccount else { return }
        let r = try await call([["ContactCard/set", ["accountId": acc, "destroy": [id]], "s"]], using: [Self.core, Self.contacts])
        if let why = (r["s"]?["notDestroyed"] as? [String: Any])?[id] as? [String: Any] {
            throw JMAPError.method(why["type"] as? String ?? "notDestroyed", why["description"] as? String ?? "")
        }
    }

    /// Your latest emails from or to any of these addresses, newest first, one per conversation.
    func recent(with addresses: [String], limit: Int = 10) async throws -> [Email] {
        let list = addresses.filter { $0.contains("@") }
        guard !list.isEmpty else { return [] }
        let conditions: [[String: Any]] = list.flatMap { [["from": $0], ["to": $0], ["cc": $0]] }
        return try await emails(filter: ["operator": "OR", "conditions": conditions], limit: limit)
    }
}

// MARK: The page

/// What the Contacts page knows, shared by its two columns in the main window: the list in the middle and the
/// chosen contact on the right, just like a folder and its emails (Paul, 20 Nov 2026: not a pop-up).
@MainActor
final class ContactsModel: ObservableObject {
    @Published var cards: [ContactCardData] = []
    @Published var books: [String: [AddressBookInfo]] = [:]
    @Published var loading = false
    @Published var problem: String?
    @Published var search = ""
    @Published var chosen: ContactCardData.ID?
    @Published var editing: ContactCardData?
    private var loaded = false

    func accounts(_ store: Store) -> [AccountState] { store.accounts.filter { $0.client.canContacts } }

    var shown: [ContactCardData] {
        let words = search.trimmingCharacters(in: .whitespaces)
        return (words.isEmpty ? cards : cards.filter { $0.matches(words) }).sorted { $0.sortKey < $1.sortKey }
    }

    var chosenCard: ContactCardData? { chosen.flatMap { id in cards.first { $0.id == id } } }

    /// Loads once each time the page is opened from the sidebar (again: `reload`).
    func load(_ store: Store, again: Bool = false) async {
        if (loaded || loading) && !again { return }
        loading = true
        problem = nil
        defer { loading = false }
        // Fetched outside the page's own task: when the page redraws (opening Contacts from the sidebar, or Add sender
        // to Contacts) SwiftUI cancels that task, which stopped the load half way with a "cancelled" error and left the
        // page empty (Paul, 21 Nov 2026). Tried twice before saying anything went wrong.
        let ready = accounts(store)
        let result = await Task { @MainActor () -> (cards: [ContactCardData], books: [String: [AddressBookInfo]], problem: String?) in
            var all: [ContactCardData] = []
            var found: [String: [AddressBookInfo]] = [:]
            var problem: String?
            for s in ready {
                for attempt in 0..<2 {
                    do {
                        let cards = try await s.client.cards(account: s.id)
                        found[s.id] = try await s.client.addressBooks()
                        all += cards
                        break
                    } catch {
                        if attempt == 0 { try? await Task.sleep(nanoseconds: 500_000_000); continue }
                        let ns = error as NSError
                        if !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) && !(error is CancellationError) {
                            problem = error.localizedDescription
                        }
                    }
                }
            }
            return (all, found, problem)
        }.value
        cards = result.cards
        books.merge(result.books) { _, new in new }
        problem = result.problem
        loaded = result.problem == nil
        #if os(macOS)
        if chosen == nil { chosen = shown.first?.id }
        #endif
    }

    func bookName(_ c: ContactCardData, store: Store) -> String? {
        let list = books[c.account] ?? []
        guard list.count > 1 || store.accounts.count > 1 else { return nil }
        let name = list.first { $0.id == c.book }?.name ?? "Contacts"
        let account = store.state(id: c.account)?.account.label
        return store.accounts.count > 1 && account != nil ? "\(name), \(account!)" : name
    }

    func startNew(_ store: Store) {
        guard let s = accounts(store).first else { return }
        let list = books[s.id] ?? []
        let book = (list.first { $0.isDefault } ?? list.first)?.id ?? ""
        editing = ContactCardData(id: "", account: s.id, book: book, emails: [ContactEntry(serverId: "", value: "", label: "")])
    }

    func saved(_ card: ContactCardData, store: Store) {
        cards.removeAll { $0.id == card.id || $0.id.isEmpty }
        cards.append(card)
        chosen = card.id
        Task { await refreshForCompose(card.account, store: store) }
    }

    func deleted(_ card: ContactCardData, store: Store) {
        cards.removeAll { $0.id == card.id }
        chosen = nil
        Task { await refreshForCompose(card.account, store: store) }
    }

    /// Compose's address suggestions come from the same address book: load them again after a change.
    private func refreshForCompose(_ account: String, store: Store) async {
        guard let s = store.state(id: account) else { return }
        s.contactsLoaded = false
        await s.loadContacts()
    }
}

/// The middle column when Contacts is chosen in the sidebar: everyone, A to Z, with search and +.
struct ContactsList: View {
    @EnvironmentObject var store: Store
    @ObservedObject var model: ContactsModel

    private var noAccess: String {
        "Contacts need Contacts access. Sign in again with Fastmail, or make a new API token with Contacts ticked."
    }

    var body: some View {
        List(selection: $model.chosen) {
            if let problem = model.problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
            if !model.loading && model.cards.isEmpty && model.problem == nil {
                Text(model.accounts(store).isEmpty ? noAccess : "No contacts yet. Press + to add one.").foregroundStyle(.secondary)
            }
            let groups = Dictionary(grouping: model.shown, by: \.letter)
            ForEach(groups.keys.sorted { $0 == "#" ? false : $1 == "#" ? true : $0 < $1 }, id: \.self) { letter in
                Section(letter) {
                    ForEach(groups[letter] ?? []) { c in
                        // Rows the size of the email list's, not a squeezed address book (Paul, 21 Nov 2026).
                        HStack(spacing: 12) {
                            Avatar(address: c.avatar, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).font(Look.size(15, weight: .semibold)).lineLimit(1)
                                let work = [c.jobTitle, c.company].filter { !$0.isEmpty }.joined(separator: ", ")
                                if let first = c.emails.first?.value, first != c.name {
                                    Text(first).font(Look.size(13)).foregroundStyle(.secondary).lineLimit(1)
                                } else if !work.isEmpty {
                                    Text(work).font(Look.size(13)).foregroundStyle(.secondary).lineLimit(1)
                                } else if let phone = c.phones.first?.value {
                                    Text(phone).font(Look.size(13)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                        .tag(c.id)
                    }
                }
            }
        }
        .overlay { if model.loading { ProgressView() } }
        .searchable(text: $model.search, prompt: "Search contacts")
        .navigationTitle("Contacts")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 460)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.startNew(store) } label: { Label("New contact", systemImage: "plus") }
                    .disabled(model.accounts(store).isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.load(store, again: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .sheet(item: $model.editing) { c in
            ContactEditor(card: c, books: model.books[c.account] ?? [],
                          saved: { model.saved($0, store: store) }, deleted: { model.deleted($0, store: store) })
                .environmentObject(store)
        }
        .task { await model.load(store) }
    }
}

/// The right-hand column when Contacts is chosen: the picked contact.
struct ContactsDetail: View {
    @EnvironmentObject var store: Store
    @ObservedObject var model: ContactsModel
    /// Starts a new email to an address.
    let compose: (String) -> Void
    /// Opens one of the recent emails (back in the mail view).
    let open: (MessageRef) -> Void

    var body: some View {
        if let c = model.chosenCard {
            ContactDetail(card: c, bookName: model.bookName(c, store: store), compose: compose,
                          edit: { model.editing = c }, open: open)
                .id(c.id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "person.crop.circle").font(Look.size(34, weight: .light)).foregroundStyle(.tertiary)
                Text("No contact selected").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One contact: details you can tap, a private note, and your recent emails with them.
private struct ContactDetail: View {
    @EnvironmentObject var store: Store
    @Environment(\.openURL) private var openURL
    let card: ContactCardData
    let bookName: String?
    let compose: (String) -> Void
    let edit: () -> Void
    let open: (MessageRef) -> Void
    @State private var recent: [Email] = []
    @State private var loadingRecent = true

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                actions
                if !card.emails.isEmpty {
                    box("Email") {
                        ForEach(card.emails) { e in
                            Button { compose(e.value) } label: { entry(e) }.buttonStyle(.plain)
                            if e.id != card.emails.last?.id { Divider() }
                        }
                    }
                }
                if !card.phones.isEmpty {
                    box("Phone") {
                        ForEach(card.phones) { p in
                            Button { if let url = tel(p.value) { openURL(url) } } label: { entry(p) }.buttonStyle(.plain)
                            if p.id != card.phones.last?.id { Divider() }
                        }
                    }
                }
                if !card.addresses.isEmpty {
                    box("Address") {
                        ForEach(card.addresses, id: \.self) { a in
                            Button { maps(a) } label: {
                                Text(a).font(Look.size(15)).foregroundStyle(Look.accent)
                                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if a != card.addresses.last { Divider() }
                        }
                    }
                }
                box("Note", footer: "Only you see this. It's saved with the contact in your address book.") {
                    if card.note.isEmpty {
                        Button(action: edit) {
                            Label("Add a private note", systemImage: "note.text.badge.plus").font(Look.size(15))
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    } else {
                        Text(card.note).font(Look.size(15)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !card.emails.isEmpty { recentBox }
            }
            .padding(.horizontal, 24).padding(.vertical, 28)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(Look.paper)
        .navigationTitle(card.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: edit) { Label("Edit", systemImage: "pencil") }.help("Edit contact")
            }
        }
        .task(id: card.emails.map(\.value).joined()) {
            loadingRecent = true
            if let s = store.state(id: card.account) {
                recent = (try? await s.client.recent(with: card.emails.map(\.value))) ?? []
            }
            loadingRecent = false
        }
    }

    /// Big picture, name, job and address book, centred, like Apple's Contacts.
    private var header: some View {
        VStack(spacing: 6) {
            Avatar(address: card.avatar, size: 96)
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                .padding(.bottom, 4)
            Text(card.name).font(Look.size(26, weight: .bold)).multilineTextAlignment(.center).textSelection(.enabled)
            let work = [card.jobTitle, card.company].filter { !$0.isEmpty }.joined(separator: ", ")
            if !work.isEmpty { Text(work).font(Look.size(15)).foregroundStyle(.secondary) }
            if let bookName { Label(bookName, systemImage: "person.2").font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity)
    }

    /// Round buttons under the name: email, call, message and map, greyed when there's nothing to use.
    private var actions: some View {
        let email: String? = card.emails.first?.value
        let call: URL? = card.phones.first.flatMap { tel($0.value) }
        let text: URL? = card.phones.first.flatMap { sms($0.value) }
        let place: String? = card.addresses.first
        var mail: (() -> Void)? = nil
        var phone: (() -> Void)? = nil
        var message: (() -> Void)? = nil
        var map: (() -> Void)? = nil
        if let email { mail = { compose(email) } }
        if let call { phone = { openURL(call) } }
        if let text { message = { openURL(text) } }
        if let place { map = { maps(place) } }
        return HStack(spacing: 12) {
            action("Email", "envelope.fill", mail)
            action("Call", "phone.fill", phone)
            action("Message", "message.fill", message)
            action("Map", "map.fill", map)
        }
        .frame(maxWidth: 420)
    }

    private func action(_ title: String, _ icon: String, _ run: (() -> Void)?) -> some View {
        Button { run?() } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
                Text(title).font(Look.size(12, weight: .medium))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .foregroundStyle(run == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Look.accent))
            .background(RoundedRectangle(cornerRadius: 12).fill(Look.ground))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(run == nil)
    }

    /// A rounded box with a small heading, like a section of Apple's Contacts card.
    private func box<Content: View>(_ title: String, footer: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Look.size(13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Look.ground))
            if let footer { Text(footer).font(.caption).foregroundStyle(.secondary).padding(.leading, 4) }
        }
    }

    private var recentBox: some View {
        box("Recent emails") {
            if loadingRecent { ProgressView().frame(maxWidth: .infinity) }
            else if recent.isEmpty { Text("No emails yet.").foregroundStyle(.secondary) }
            ForEach(recent) { e in
                Button { open(MessageRef(account: card.account, email: e.id)) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(e.subject?.isEmpty == false ? e.subject! : "(no subject)")
                                .font(Look.size(15, weight: e.isUnread ? .semibold : .medium)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(When.short(e.date)).font(Look.size(12.5)).foregroundStyle(.secondary)
                        }
                        if let p = e.preview, !p.isEmpty {
                            Text(p).font(Look.size(13)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if e.id != recent.last?.id { Divider() }
            }
        }
    }

    private func maps(_ a: String) {
        var c = URLComponents(string: "https://maps.apple.com/")!
        c.queryItems = [URLQueryItem(name: "q", value: a)]
        if let url = c.url { openURL(url) }
    }

    private func sms(_ number: String) -> URL? {
        URL(string: "sms:" + number.filter { "+0123456789".contains($0) })
    }

    /// The label small on top ("mobile", "work"), the number or address under it in the accent colour.
    private func entry(_ e: ContactEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !e.label.isEmpty { Text(e.label).font(Look.size(12)).foregroundStyle(.secondary) }
            Text(e.value).font(Look.size(15)).foregroundStyle(Look.accent).lineLimit(1).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func tel(_ number: String) -> URL? {
        URL(string: "tel:" + number.filter { "+0123456789".contains($0) })
    }
}

/// Adding or changing a contact.
private struct ContactEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var card: ContactCardData
    let books: [AddressBookInfo]
    let saved: (ContactCardData) -> Void
    let deleted: (ContactCardData) -> Void
    @State private var working = false
    @State private var problem: String?
    @State private var confirmDelete = false

    private let labels = ["", "home", "work", "mobile", "other"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("First name", text: $card.given)
                    TextField("Last name", text: $card.surname)
                    TextField("Company", text: $card.company)
                    TextField("Job title", text: $card.jobTitle)
                }
                Section("Email") {
                    ForEach($card.emails) { $e in row($e, prompt: "Email address", email: true) }
                        .onDelete { card.emails.remove(atOffsets: $0) }
                    Button { card.emails.append(ContactEntry(serverId: "", value: "", label: "")) } label: {
                        Label("Add email", systemImage: "plus.circle.fill")
                    }
                }
                Section("Phone") {
                    ForEach($card.phones) { $p in row($p, prompt: "Phone number", email: false) }
                        .onDelete { card.phones.remove(atOffsets: $0) }
                    Button { card.phones.append(ContactEntry(serverId: "", value: "", label: "mobile")) } label: {
                        Label("Add phone", systemImage: "plus.circle.fill")
                    }
                }
                Section {
                    TextField("Private note", text: $card.note, axis: .vertical).lineLimit(3...8)
                } header: { Text("Note") } footer: { Text("Only you see this.") }
                if card.id.isEmpty && books.count > 1 {
                    Picker(selection: $card.book) {
                        ForEach(books) { b in Text(b.shared ? "\(b.name) (shared)" : b.name).tag(b.id) }
                    } label: { Label("Address book", systemImage: "person.2") }
                }
                if !card.id.isEmpty {
                    Section {
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete contact", systemImage: "trash") }
                    }
                }
                if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle(card.id.isEmpty ? "New contact" : "Edit contact")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label("Cancel", systemImage: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if working { ProgressView().controlSize(.small) } else { Label("Save", systemImage: "checkmark") }
                    }
                    .disabled(working || !canSave)
                }
            }
            .confirmationDialog("Delete \(card.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(role: .destructive) { Task { await delete() } } label: { Label("Delete contact", systemImage: "trash") }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It's removed from your address book everywhere, including Fastmail on the web.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    private var canSave: Bool {
        !(card.given + card.surname + card.company).trimmingCharacters(in: .whitespaces).isEmpty
            || card.emails.contains { $0.value.contains("@") }
    }

    private func row(_ e: Binding<ContactEntry>, prompt: String, email: Bool) -> some View {
        HStack {
            Picker("", selection: e.label) {
                ForEach(labels, id: \.self) { Text($0.isEmpty ? "none" : $0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 100)
            TextField(prompt, text: e.value)
                #if os(iOS)
                .keyboardType(email ? .emailAddress : .phonePad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
        }
    }

    private func save() async {
        guard let s = store.state(id: card.account) else { return }
        working = true; problem = nil
        defer { working = false }
        do {
            var c = card
            c.emails = c.emails.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            c.phones = c.phones.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            let id = try await s.client.save(c)
            // Read it back so ids for new emails and phones match the server's.
            let fresh = try await s.client.cards(account: s.id).first { $0.id == id }
            c.id = id
            saved(fresh ?? c)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func delete() async {
        guard let s = store.state(id: card.account) else { return }
        working = true; problem = nil
        defer { working = false }
        do {
            try await s.client.deleteCard(card.id)
            deleted(card)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
