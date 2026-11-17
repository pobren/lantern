// People: email that reads like Messages. Pick a person and see what you've said to each other as bubbles,
// with quoted replies trimmed away, and answer from the box at the bottom.

import SwiftUI

struct PeopleView: View {
    @EnvironmentObject var store: Store
    @State private var chosen: String?
    @State private var search = ""

    private var people: [Person] {
        let all = store.people
        guard !search.isEmpty else { return all }
        return all.filter { $0.address.display.localizedCaseInsensitiveContains(search) || $0.address.email.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("Search people", text: $search).textFieldStyle(.roundedBorder).padding(12)
                List(people, selection: $chosen) { p in
                    HStack(spacing: 12) {
                        Avatar(address: p.address, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(p.address.display).fontWeight(p.unread > 0 ? .bold : .medium)
                                Spacer()
                                Text(p.latest.map { When.short($0.date) } ?? "").font(.caption)
                                    .foregroundStyle(p.unread > 0 ? Look.accent : .secondary)
                            }
                            Text(p.latest?.preview ?? "").font(.callout).lineLimit(1)
                                .foregroundStyle(p.unread > 0 ? Look.ink : .secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(p.id)
                }
                .listStyle(.inset)
            }
            .frame(width: 320)
            .background(Look.ground)
            Divider()
            if let id = chosen ?? people.first?.id, let person = store.people.first(where: { $0.id == id }) {
                ConversationView(person: person).id(person.id)
            } else {
                ContentUnavailableView("No conversations yet", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("People you write to show up here."))
            }
        }
        .navigationTitle("People")
    }
}

struct ConversationView: View {
    @EnvironmentObject var store: Store
    let person: Person
    @State private var replyText = ""
    @State private var sending = false

    private var items: [Item] {
        person.emails.sorted { $0.date < $1.date }.compactMap { e in
            store.accounts.first { s in s.inbox.contains(e) || s.sent.contains(e) }.map { Item(account: $0.account, email: e) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Avatar(address: person.address, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.address.display).font(.system(size: 15, weight: .semibold))
                    Text("\(person.address.email) · \(person.emails.count) emails").font(.caption).foregroundStyle(Look.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 24).frame(height: 64)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(items) { item in Bubble(item: item, mine: store.isMine(item.email)).id(item.id) }
                    }
                    .padding(.horizontal, 32).padding(.vertical, 20)
                }
                .onAppear { if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            replyBar
        }
        .background(Color.white)
        .task {
            for item in items where item.email.isUnread { await store.markRead(item) }
        }
    }

    private var lastFromThem: Item? { items.last { !store.isMine($0.email) } }

    private var replyBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let last = lastFromThem {
                HStack(spacing: 6) {
                    AccountDot(account: last.account)
                    Text("Replying from \(store.state(for: last.account)?.identities.first?.email ?? last.account.username)")
                }
                .font(.caption).foregroundStyle(Look.muted)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Reply to \(person.address.firstName)", text: $replyText, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...6).padding(.vertical, 8)
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 32, height: 32).background(Circle().fill(Look.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending || lastFromThem == nil)
                .accessibilityLabel("Send")
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 22).fill(Look.ground))
        }
        .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 18)
    }

    private func send() async {
        guard let last = lastFromThem, let s = store.state(for: last.account), let identity = s.identities.first else { return }
        sending = true
        defer { sending = false }
        let subject = last.email.title.lowercased().hasPrefix("re:") ? last.email.title : "Re: \(last.email.title)"
        do {
            try await store.send(account: last.account, identity: identity, to: [person.address], cc: [], subject: subject,
                                 text: replyText, replyTo: last.email)
            replyText = ""
        } catch {
            store.problem = error.localizedDescription
        }
    }
}

struct Bubble: View {
    @EnvironmentObject var store: Store
    let item: Item
    let mine: Bool
    @State private var text: String?

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            Text(item.email.title).font(.system(size: 11)).foregroundStyle(Look.muted)
            Text(text ?? item.email.preview ?? "")
                .font(.system(size: 14)).lineSpacing(3)
                .foregroundStyle(mine ? Color.white : Look.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 15).padding(.vertical, 11)
                .background(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: mine ? 18 : 6,
                                                   bottomTrailingRadius: mine ? 6 : 18, topTrailingRadius: 18)
                    .fill(mine ? Look.accent : Look.ground))
            HStack(spacing: 6) {
                if item.email.hasAttachment == true { Image(systemName: "paperclip") }
                Text(When.short(item.email.date))
            }
            .font(.system(size: 11)).foregroundStyle(Look.muted)
        }
        .frame(maxWidth: 520, alignment: mine ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .task { text = await store.body(item) }
    }
}
