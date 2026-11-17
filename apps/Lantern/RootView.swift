// The window: a slim sidebar of places (Today, People, Focus, Inbox) and the chosen place beside it.
// With no account yet, the welcome screen fills the window instead.

import SwiftUI

enum Place: String, Hashable, CaseIterable {
    case today = "Today"
    case people = "People"
    case focus = "Focus"
    case inbox = "Inbox"

    var icon: String {
        switch self {
        case .today: return "sun.max"
        case .people: return "person.2"
        case .focus: return "scope"
        case .inbox: return "tray"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @State private var place: Place? = .today
    @State private var composing: ComposeDraft?
    @State private var opened: Item?

    var body: some View {
        Group {
            if store.hasAccounts {
                NavigationSplitView {
                    sidebar
                } detail: {
                    detail
                }
                .task { await store.start() }
            } else {
                WelcomeView()
            }
        }
        .sheet(item: $composing) { draft in ComposeView(draft: draft).environmentObject(store) }
        .sheet(item: $opened) { item in
            MessageView(item: item, onReply: { composing = ComposeDraft.reply(to: item, store: store) })
                .environmentObject(store)
                .frame(minWidth: 680, minHeight: 560)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lanternCompose)) { _ in composing = ComposeDraft.new(store: store) }
        .overlay(alignment: .bottom) {
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 18)
                    .onTapGesture { store.problem = nil }
            }
        }
    }

    private var sidebar: some View {
        List(selection: $place) {
            Section {
                ForEach(Place.allCases, id: \.self) { p in
                    Label(p.rawValue, systemImage: p.icon)
                        .badge(badge(p))
                        .tag(p)
                }
            }
            Section("Accounts") {
                ForEach(store.accounts) { s in
                    HStack(spacing: 8) {
                        AccountDot(account: s.account, size: 8)
                        Text(s.account.label)
                        Spacer()
                        Text("\(s.inbox.filter { $0.isUnread }.count)").foregroundStyle(.secondary).font(.caption)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Circle().fill(store.loading ? Color.orange : Color.green).frame(width: 7, height: 7)
                Text(store.loading ? "Checking for mail" : "Up to date, live over JMAP").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { composing = ComposeDraft.new(store: store) } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .help("New message (⌘N)")
                    .accessibilityLabel("New message")
            }
            .padding(12)
        }
    }

    private func badge(_ p: Place) -> Int {
        switch p {
        case .today: return store.needsYou.filter { $0.email.isUnread }.count
        case .focus: return store.focusQueue.count
        case .inbox: return store.inboxItems.filter { $0.email.isUnread }.count
        case .people: return 0
        }
    }

    @ViewBuilder private var detail: some View {
        switch place ?? .today {
        case .today:
            TodayView(open: { opened = $0 }, reply: { composing = ComposeDraft.reply(to: $0, store: store) })
        case .people:
            PeopleView()
        case .focus:
            FocusView(reply: { composing = ComposeDraft.reply(to: $0, store: store) })
        case .inbox:
            InboxView(open: { opened = $0 })
        }
    }
}

/// A plain list of everything in every inbox, newest first.
struct InboxView: View {
    @EnvironmentObject var store: Store
    let open: (Item) -> Void

    var body: some View {
        List(store.inboxItems) { item in
            Button { open(item) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(item.email.isUnread ? Look.accent : Color.clear).frame(width: 8, height: 8).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(item.email.sender.display).fontWeight(item.email.isUnread ? .semibold : .regular)
                            Spacer()
                            Text(When.short(item.email.date)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(item.email.title).fontWeight(item.email.isUnread ? .semibold : .regular).lineLimit(1)
                        Text(item.email.preview ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        HStack(spacing: 6) { AccountDot(account: item.account, size: 6); Text(item.account.label) }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Done") { Task { await store.done(item) } }
                Button("Later") { store.putOff(item) }
                Button(item.email.isFlagged ? "Remove star" : "Star") { Task { await store.flag(item) } }
                Divider()
                Button("Delete", role: .destructive) { Task { await store.delete(item) } }
            }
        }
        .navigationTitle("Inbox")
    }
}
