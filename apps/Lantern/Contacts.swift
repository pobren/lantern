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
    func recent(with addresses: [String], limit: Int = 8) async throws -> [Email] {
        let list = addresses.filter { $0.contains("@") }
        guard !list.isEmpty else { return [] }
        let conditions: [[String: Any]] = list.flatMap { [["from": $0], ["to": $0], ["cc": $0]] }
        return try await emails(filter: ["operator": "OR", "conditions": conditions], limit: limit)
    }
}

// MARK: The page

struct ContactsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    /// Starts a new email to an address (the page closes first).
    let compose: (String) -> Void

    @State private var cards: [ContactCardData] = []
    @State private var books: [String: [AddressBookInfo]] = [:]
    @State private var loading = true
    @State private var problem: String?
    @State private var search = ""
    @State private var chosen: ContactCardData.ID?
    @State private var editing: ContactCardData?

    private var accounts: [AccountState] { store.accounts.filter { $0.client.canContacts } }

    private var shown: [ContactCardData] {
        let words = search.trimmingCharacters(in: .whitespaces)
        return (words.isEmpty ? cards : cards.filter { $0.matches(words) }).sorted { $0.sortKey < $1.sortKey }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $chosen) {
                if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                if !loading && cards.isEmpty && problem == nil {
                    Text(accounts.isEmpty ? noAccess : "No contacts yet. Press + to add one.").foregroundStyle(.secondary)
                }
                let groups = Dictionary(grouping: shown, by: \.letter)
                ForEach(groups.keys.sorted { $0 == "#" ? false : $1 == "#" ? true : $0 < $1 }, id: \.self) { letter in
                    Section(letter) {
                        ForEach(groups[letter] ?? []) { c in
                            HStack(spacing: 10) {
                                Avatar(address: c.avatar, size: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.name).lineLimit(1)
                                    if let first = c.emails.first?.value, first != c.name {
                                        Text(first).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .tag(c.id)
                        }
                    }
                }
            }
            .overlay { if loading { ProgressView() } }
            .searchable(text: $search, prompt: "Search contacts")
            .navigationTitle("Contacts")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 230, ideal: 260)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label("Done", systemImage: "checkmark") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { startNew() } label: { Label("New contact", systemImage: "plus") }
                        .disabled(accounts.isEmpty)
                }
            }
        } detail: {
            if let id = chosen, let c = cards.first(where: { $0.id == id }) {
                ContactDetail(card: c, bookName: bookName(c), compose: { address in dismiss(); compose(address) },
                              edit: { editing = c }, open: { ref in dismiss(); Task { await store.show(ref) } })
                    .id(c.id)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle").font(Look.size(34, weight: .light)).foregroundStyle(.tertiary)
                    Text("No contact selected").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $editing) { c in
            ContactEditor(card: c, books: books[c.account] ?? [], saved: { saved in
                cards.removeAll { $0.id == saved.id || ($0.id.isEmpty) }
                cards.append(saved)
                chosen = saved.id
                Task { await refreshContactsForCompose(saved.account) }
            }, deleted: { gone in
                cards.removeAll { $0.id == gone.id }
                chosen = nil
                Task { await refreshContactsForCompose(gone.account) }
            })
            .environmentObject(store)
        }
        .task { await load() }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 540)
        #endif
    }

    private var noAccess: String {
        "Contacts need Contacts access. Sign in again with Fastmail, or make a new API token with Contacts ticked."
    }

    private func bookName(_ c: ContactCardData) -> String? {
        let list = books[c.account] ?? []
        guard list.count > 1 || store.accounts.count > 1 else { return nil }
        let name = list.first { $0.id == c.book }?.name ?? "Contacts"
        let account = store.state(id: c.account)?.account.label
        return store.accounts.count > 1 && account != nil ? "\(name), \(account!)" : name
    }

    private func load() async {
        loading = true
        defer { loading = false }
        var all: [ContactCardData] = []
        for s in accounts {
            do {
                all += try await s.client.cards(account: s.id)
                books[s.id] = try await s.client.addressBooks()
            } catch {
                problem = error.localizedDescription
            }
        }
        cards = all
        #if os(macOS)
        if chosen == nil { chosen = shown.first?.id }
        #endif
    }

    private func startNew() {
        guard let s = accounts.first else { return }
        let list = books[s.id] ?? []
        let book = (list.first { $0.isDefault } ?? list.first)?.id ?? ""
        editing = ContactCardData(id: "", account: s.id, book: book, emails: [ContactEntry(serverId: "", value: "", label: "")])
    }

    /// Compose's address suggestions come from the same address book: load them again after a change.
    private func refreshContactsForCompose(_ account: String) async {
        guard let s = store.state(id: account) else { return }
        s.contactsLoaded = false
        await s.loadContacts()
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
        List {
            Section {
                HStack(spacing: 14) {
                    Avatar(address: card.avatar, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(card.name).font(Look.size(22, weight: .semibold)).textSelection(.enabled)
                        let work = [card.jobTitle, card.company].filter { !$0.isEmpty }.joined(separator: ", ")
                        if !work.isEmpty { Text(work).foregroundStyle(.secondary) }
                        if let bookName { Label(bookName, systemImage: "person.2").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .padding(.vertical, 4)
                HStack(spacing: 10) {
                    if let first = card.emails.first {
                        Button { compose(first.value) } label: { Label("Email", systemImage: "envelope.fill") }
                            .buttonStyle(.borderedProminent)
                    }
                    if let phone = card.phones.first, let url = tel(phone.value) {
                        Button { openURL(url) } label: { Label("Call", systemImage: "phone.fill") }
                            .buttonStyle(.bordered)
                    }
                }
            }
            if !card.emails.isEmpty {
                Section("Email") {
                    ForEach(card.emails) { e in
                        Button { compose(e.value) } label: { entry(e, icon: "envelope") }.buttonStyle(.plain)
                    }
                }
            }
            if !card.phones.isEmpty {
                Section("Phone") {
                    ForEach(card.phones) { p in
                        Button { if let url = tel(p.value) { openURL(url) } } label: { entry(p, icon: "phone") }.buttonStyle(.plain)
                    }
                }
            }
            if !card.addresses.isEmpty {
                Section("Address") {
                    ForEach(card.addresses, id: \.self) { a in
                        Button {
                            var c = URLComponents(string: "https://maps.apple.com/")!
                            c.queryItems = [URLQueryItem(name: "q", value: a)]
                            if let url = c.url { openURL(url) }
                        } label: { Label(a, systemImage: "map").fixedSize(horizontal: false, vertical: true) }.buttonStyle(.plain)
                    }
                }
            }
            Section {
                if card.note.isEmpty {
                    Button(action: edit) { Label("Add a private note", systemImage: "note.text.badge.plus") }.buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                } else {
                    Text(card.note).textSelection(.enabled)
                }
            } header: { Text("Note") } footer: { Text("Only you see this. It's saved with the contact in your address book.") }
            if !card.emails.isEmpty {
                Section("Recent emails") {
                    if loadingRecent { ProgressView().frame(maxWidth: .infinity) }
                    else if recent.isEmpty { Text("No emails yet.").foregroundStyle(.secondary) }
                    ForEach(recent) { e in
                        Button { open(MessageRef(account: card.account, email: e.id)) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(e.subject?.isEmpty == false ? e.subject! : "(no subject)").lineLimit(1)
                                    Spacer()
                                    Text(e.date, format: .dateTime.day().month(.abbreviated).year()).font(.caption).foregroundStyle(.secondary)
                                }
                                if let p = e.preview, !p.isEmpty { Text(p).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(card.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: edit) { Label("Edit", systemImage: "pencil") }
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

    private func entry(_ e: ContactEntry, icon: String) -> some View {
        HStack {
            Label(e.value, systemImage: icon).lineLimit(1)
            Spacer()
            if !e.label.isEmpty { Text(e.label).font(.caption).foregroundStyle(.secondary) }
        }
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
