// Select several emails (Paul, 21 Nov 2026): a Select button above the list puts a circle by each email; tick as many
// as you like, then archive, delete, move, mark read or star them all at once. One Undo puts them all back.

import SwiftUI

extension Store {
    var pickedItems: [Item] { list.filter { picked.contains($0.id) } }

    func endSelecting() { selecting = false; picked = [] }

    func togglePicked(_ item: Item) {
        if picked.contains(item.id) { picked.remove(item.id) } else { picked.insert(item.id) }
    }

    /// Runs a move on every picked conversation, with one Undo for all of them.
    func bulkMove(_ title: (Int) -> String, _ work: (Item) async -> Void) async {
        let items = pickedItems
        guard !items.isEmpty else { return }
        UndoMove.shared.startCollecting()
        for item in items { await work(item) }
        UndoMove.shared.finishCollecting(title: title(items.count))
        endSelecting()
    }

    func bulkArchive() async {
        await bulkMove({ $0 == 1 ? "Archived 1 conversation" : "Archived \($0) conversations" }) { await self.archive($0) }
    }

    func bulkDelete() async {
        await bulkMove({ $0 == 1 ? "Deleted 1 conversation" : "Deleted \($0) conversations" }) { await self.delete($0) }
    }

    func bulkMove(to target: Mailbox) async {
        await bulkMove({ "Moved \($0) to \(target.name)" }) { item in
            // Only conversations in the same account as the folder can go there.
            guard item.account.id == self.state(for: target)?.id else { return }
            await self.move(item, to: target)
        }
    }

    func bulkRead(_ read: Bool) async {
        for item in pickedItems where item.email.isUnread == read { await setUnread(item, !read) }
        endSelecting()
    }

    func bulkStar() async {
        let items = pickedItems
        let on = items.contains { !$0.email.isFlagged }
        for item in items where item.email.isFlagged != on { await flag(item) }
        endSelecting()
    }

    /// The account a folder belongs to.
    func state(for box: Mailbox) -> AccountState? {
        accounts.first { s in s.mailboxes.contains { $0.id == box.id } }
    }
}

extension UndoMove {
    func startCollecting() { collecting = true; collected = [:]; collectedAccount = nil }

    func finishCollecting(title: String) {
        collecting = false
        guard let account = collectedAccount, !collected.isEmpty else { return }
        last = Done(title: title, account: account, patches: collected, more: extraAccounts)
        collected = [:]
        extraAccounts = [:]
    }
}

/// The Select button above the list.
struct SelectButton: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Button {
            if store.selecting { store.endSelecting() } else { store.selecting = true }
        } label: {
            Label(store.selecting ? "Done" : "Select", systemImage: store.selecting ? "checkmark.circle.fill" : "checkmark.circle")
        }
        .help(store.selecting ? "Stop selecting" : "Select several emails")
    }
}

/// The bar along the bottom of the list while selecting.
struct SelectionBar: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let count = store.picked.count
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                Button {
                    if count == store.list.count { store.picked = [] } else { store.picked = Set(store.list.map(\.id)) }
                } label: { Text(count == store.list.count && count > 0 ? "None" : "All") }
                    .buttonStyle(.borderless)
                Text(count == 0 ? "Select emails" : "\(count) selected").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Group {
                    Button { Task { await store.bulkArchive() } } label: { Label("Archive", systemImage: "archivebox") }
                    Button { Task { await store.bulkDelete() } } label: { Label("Delete", systemImage: "trash") }
                    Menu {
                        let accounts = Set(store.pickedItems.map(\.account.id))
                        ForEach(store.accounts.filter { accounts.contains($0.id) }) { s in
                            Section(store.accounts.count > 1 ? s.account.label : "") {
                                ForEach(s.tree) { entry in
                                    Button(String(repeating: "  ", count: entry.depth) + entry.box.name) {
                                        Task { await store.bulkMove(to: entry.box) }
                                    }
                                }
                            }
                        }
                    } label: { Label("Move to", systemImage: "folder") }
                    Menu {
                        Button { Task { await store.bulkRead(true) } } label: { Label("Mark as read", systemImage: "envelope.open") }
                        Button { Task { await store.bulkRead(false) } } label: { Label("Mark as unread", systemImage: "envelope.badge") }
                        Button { Task { await store.bulkStar() } } label: { Label("Star", systemImage: "star") }
                    } label: { Label("More", systemImage: "ellipsis.circle") }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(count == 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .background(.bar)
    }
}
