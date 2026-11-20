// Five things from Apple Mail's menus (Paul picked them, 20 Nov 2026):
//
// - Undo: after Delete, Archive, Move or Spam, a bar offers Undo for a few seconds (⌘Z), and puts the
//   conversation back exactly where it was.
// - Move again: repeats the last Move to with one key (⌥⌘T on the Mac, as in Apple Mail).
// - Forward as attachment: the original email goes along as a file, untouched.
// - Add sender to Contacts: opens a new contact with the sender's name and address filled in, ready to save.
// - Filter: the list shows only unread, starred or with attachments.

import SwiftUI

// MARK: Filter

enum ListFilter: String, CaseIterable, Identifiable {
    case all, unread, starred, attachments
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All mail"
        case .unread: return "Unread"
        case .starred: return "Starred"
        case .attachments: return "With attachments"
        }
    }

    var icon: String {
        switch self {
        case .all: return "tray"
        case .unread: return "envelope.badge"
        case .starred: return "star"
        case .attachments: return "paperclip"
        }
    }

    /// The JMAP condition for the server.
    var condition: [String: Any]? {
        switch self {
        case .all: return nil
        case .unread: return ["notKeyword": "$seen"]
        case .starred: return ["hasKeyword": "$flagged"]
        case .attachments: return ["hasAttachment": true]
        }
    }

    /// The same test on an email already on the device.
    func matches(_ e: Email) -> Bool {
        switch self {
        case .all: return true
        case .unread: return e.isUnread
        case .starred: return e.isFlagged
        case .attachments: return e.hasAttachment == true
        }
    }
}

/// The filter button above the list.
struct ListFilterMenu: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Menu {
            Picker("Show", selection: Binding(get: { store.listFilter }, set: { f in
                store.listFilter = f
                Task { await store.reloadList() }
            })) {
                ForEach(ListFilter.allCases) { f in Label(f.title, systemImage: f.icon).tag(f) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Filter", systemImage: store.listFilter == .all
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .help(store.listFilter == .all ? "Show only unread, starred or with attachments" : "Showing: \(store.listFilter.title)")
    }
}

// MARK: Undo

@MainActor
final class UndoMove: ObservableObject {
    static let shared = UndoMove()

    struct Done: Identifiable {
        let id = UUID()
        let title: String
        let account: Account
        /// Each email's mailboxes (and spam marks) as they were before.
        let patches: [String: [String: Any]]
    }

    @Published var last: Done?
    @Published var working = false

    func offer(_ d: Done) { last = d }
}

extension Store {
    /// Puts the last moved conversation back where it was.
    func undoLastMove() async {
        let undo = UndoMove.shared
        guard let d = undo.last, let s = state(for: d.account), !undo.working else { return }
        undo.working = true
        defer { undo.working = false; if undo.last?.id == d.id { undo.last = nil } }
        await apply(d.patches, in: s)
        await refresh()
    }

    /// The folder Move again would use for this conversation, if it's in the same account.
    func moveAgainTarget(for item: Item) -> Mailbox? {
        guard let last = lastMove, last.account == item.account.id, let s = state(for: item.account) else { return nil }
        return s.box(id: last.box)
    }

    func moveAgain(_ item: Item) async {
        guard let target = moveAgainTarget(for: item) else {
            problem = "Use Move to first, then Move again repeats it."
            return
        }
        await move(item, to: target)
    }
}

/// "Archived · Undo" along the bottom of the window for a few seconds after a move.
struct UndoMoveBar: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var undo = UndoMove.shared

    var body: some View {
        if let d = undo.last {
            HStack(spacing: 12) {
                Label(d.title, systemImage: "checkmark.circle")
                Button {
                    Task { await store.undoLastMove() }
                } label: {
                    if undo.working { ProgressView().controlSize(.small) } else { Label("Undo", systemImage: "arrow.uturn.backward") }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(undo.working)
                .keyboardShortcut("z", modifiers: .command)
            }
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .padding(.bottom, 18)
            .task(id: d.id) {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if undo.last?.id == d.id && !undo.working { undo.last = nil }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: Forward as attachment

extension ComposeDraft {
    /// A forward with the original email attached as an .eml file, exactly as it arrived.
    @MainActor static func forwardAsAttachment(_ e: Email, account: Account, store: Store) async -> ComposeDraft? {
        guard let s = store.state(for: account) else { return nil }
        var blob = e.blobId
        if blob == nil { blob = try? await s.client.email(e.id)?.blobId }
        guard let blob else {
            store.problem = "Couldn't attach the original email."
            return nil
        }
        let title = e.title
        let identity = store.defaultIdentity(s)
        let sig = identity.map { signed(store.signature(for: $0)) } ?? ""
        let safe = String(title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " ").prefix(120))
        return ComposeDraft(account: account, identityId: identity?.id,
                            subject: title.lowercased().hasPrefix("fwd:") ? title : "Fwd: \(title)",
                            text: sig.isEmpty ? "" : "\n\n" + sig,
                            attachments: [Outgoing(blobId: blob, name: (safe.isEmpty ? "Email" : safe) + ".eml",
                                                   type: "message/rfc822", size: 0)])
    }
}

// MARK: Add sender to Contacts

/// Asks the main window to open Contacts with a new card for this person.
struct AddContactRequest {
    let name: String
    let email: String
    let account: String

    static let note = Notification.Name("lanternAddContact")

    func post() { NotificationCenter.default.post(name: Self.note, object: nil, userInfo: ["request": self]) }
}

extension ContactsModel {
    /// Shows the person if they're already a contact; otherwise opens a new card with their name and address.
    func add(_ r: AddContactRequest, store: Store) async {
        await load(store)
        // The Contacts page may have started loading a moment earlier: wait for it.
        for _ in 0..<100 where loading { try? await Task.sleep(nanoseconds: 100_000_000) }
        let key = r.email.lowercased()
        if let found = cards.first(where: { $0.emails.contains { $0.value.lowercased() == key } }) {
            search = ""
            chosen = found.id
            return
        }
        let ready = accounts(store)
        guard let s = ready.first(where: { $0.id == r.account }) ?? ready.first else {
            problem = "Contacts need Contacts access. Sign in again with Fastmail, or make a new API token with Contacts ticked."
            return
        }
        let list = books[s.id] ?? []
        let book = (list.first { $0.isDefault } ?? list.first)?.id ?? ""
        var given = r.name.trimmingCharacters(in: .whitespaces)
        var surname = ""
        if given.contains("@") { given = "" }
        if let space = given.lastIndex(of: " ") {
            surname = String(given[given.index(after: space)...])
            given = String(given[..<space])
        }
        editing = ContactCardData(id: "", account: s.id, book: book, given: given, surname: surname,
                                  emails: [ContactEntry(serverId: "", value: r.email, label: "")])
    }
}
