// The main window, laid out the way people expect a mail app to be: folders on the left, the list of
// conversations in the middle, the open conversation on the right. On iPhone the same three columns become
// three screens you move through.

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct RootView: View {
    @EnvironmentObject var store: Store
    @State private var composing: ComposeDraft?
    @State private var settings = false
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var compact: NavigationSplitViewColumn = {
        switch Demo.screen {
        case "folders": return .sidebar
        case "email", "compose": return .detail
        default: return .content
        }
    }()

    private var sidebar: some View {
        Sidebar(compose: { composing = ComposeDraft.new(store: store) }, settings: { settings = true })
    }
    private var middle: some View {
        MessageList(compose: { composing = ComposeDraft.new(store: store) })
    }
    @ViewBuilder private var detail: some View {
        if let item = store.selectedItem {
            ReadingPane(item: item, compose: { composing = $0 })
                .id(item.id)
        } else {
            Empty()
        }
    }

    /// For the App Store screenshots (launched with -JCDemo -JCScreen name): open the screen each shot shows.
    private func showScreen() async {
        let screen = Demo.screen ?? "email"
        #if os(macOS)
        let openEmail = true
        if ProcessInfo.processInfo.arguments.contains("-JCDark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        NSLog("JCDEBUG showing \(screen), \(store.list.count) emails"); fflush(stdout)
        // A tidy, consistent window size for the Mac shots (1440 by 900 with a caption above).
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            w.setFrame(NSRect(x: 60, y: 60, width: 1280, height: 740), display: true)
            w.makeKeyAndOrderFront(nil)
        }
        #else
        let openEmail = screen == "email" || UIDevice.current.userInterfaceIdiom == .pad
        #endif
        if openEmail { store.selection = store.list.first?.id }
        try? await Task.sleep(nanoseconds: 600_000_000)
        switch screen {
        case "compose":
            var d = ComposeDraft.new(store: store)
            d.to = "Maya Chen <maya@studio-north.example>"
            d.subject = "Re: Sketches for the spring launch"
            d.text = "Hi Maya,\n\nThe second direction is lovely. Let's go with that one, and I'll send the final copy on Thursday.\n\nThanks,\nSam" + d.text
            composing = d
        case "settings":
            settings = true
        default:
            break
        }
        #if os(macOS)
        // The screenshot workflow picks up the picture the app draws of its own window.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await Snapshot.save(screen)
        #endif
    }

    var body: some View {
        Group {
            if store.hasAccounts {
                Group {
                    if Demo.screen != nil {
                        // Screenshots: start on the column the shot needs, on iPhone too.
                        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compact) { sidebar } content: { middle } detail: { detail }
                    } else {
                        NavigationSplitView(columnVisibility: $columns) { sidebar } content: { middle } detail: { detail }
                    }
                }
                .task {
                    await store.start()
                    if Demo.launchedForScreens { await showScreen() }
                }
            } else {
                WelcomeView()
            }
        }
        .sheet(item: $composing) { draft in ComposeView(draft: draft).environmentObject(store) }
        .sheet(isPresented: $settings) { SettingsView().environmentObject(store) }
        .onReceive(NotificationCenter.default.publisher(for: .lanternCompose)) { _ in composing = ComposeDraft.new(store: store) }
        .overlay(alignment: .bottom) {
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 18)
                    .onTapGesture { store.problem = nil }
                    .task(id: problem) {
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        if store.problem == problem { store.problem = nil }
                    }
            }
        }
    }
}

private struct Empty: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "envelope.open").font(Look.size(34, weight: .light)).foregroundStyle(.tertiary)
            Text("No conversation selected").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Look.paper)
    }
}

// MARK: Folders

struct Sidebar: View {
    @EnvironmentObject var store: Store
    let compose: () -> Void
    let settings: () -> Void

    @State private var naming: Naming?
    @State private var inboxTargeted = false
    @State private var folderName = ""

    private var picked: Binding<Folder?> {
        Binding(get: { store.folder }, set: { f in if let f { Task { await store.open(f) } } })
    }

    var body: some View {
        List(selection: picked) {
            Section {
                Label(store.accounts.count > 1 ? "All inboxes" : "Inbox", systemImage: "tray.2")
                    .badge(store.unreadInboxes)
                    .background(RoundedRectangle(cornerRadius: 6).fill(inboxTargeted ? Look.accent.opacity(0.22) : .clear).padding(-4))
                    // Dropped here, a conversation goes back to its own account's inbox.
                    .dropDestination(for: String.self) { ids, _ in
                        let result = ids
                        Task { await store.dropOnInboxes(result) }
                        return true
                    } isTargeted: { inboxTargeted = $0 }
                    .tag(Folder.allInboxes)
            }
            ForEach(store.accounts) { s in
                Section {
                    ForEach(s.tree) { entry in
                        if !(store.accounts.count == 1 && entry.box.role == "inbox") && !store.isHidden(entry, in: s) {
                            FolderRow(entry: entry, state: s, naming: $naming)
                                .tag(Folder.mailbox(account: s.id, id: entry.box.id))
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        AccountDot(account: s.account, size: 7)
                        Text(s.account.label).lineLimit(1)
                    }
                    .contextMenu {
                        Button { naming = Naming(state: s, box: nil, renaming: false) } label: { Label("New folder", systemImage: "folder.badge.plus") }
                    }
                }
            }
        }
        .alert(naming?.title ?? "", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $folderName)
            Button("Cancel", role: .cancel) { naming = nil }
            Button(naming?.renaming == true ? "Rename" : "Create") {
                if let n = naming {
                    let name = folderName
                    Task {
                        if n.renaming, let box = n.box { await store.rename(box, to: name, in: n.state) }
                        else { await store.newFolder(name, in: n.state, inside: n.box) }
                    }
                }
                naming = nil
            }
        }
        .onChange(of: naming?.id) { _, _ in folderName = naming?.renaming == true ? (naming?.box?.name ?? "") : "" }
        .listStyle(.sidebar)
        .modifier(SolidForScreenshots())
        .navigationTitle("Mail")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Button(action: compose) { Label("New message", systemImage: "square.and.pencil") }
                        .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
            }
            .background(.bar)
        }
        #else
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: settings) { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: compose) { Image(systemName: "square.and.pencil") }.accessibilityLabel("New message")
            }
        }
        #endif
    }
}

/// A folder being named: a new one (inside `box`, if set) or `box` itself being renamed.
struct Naming: Identifiable {
    let id = UUID()
    let state: AccountState
    let box: Mailbox?
    let renaming: Bool
    var title: String { renaming ? "Rename folder" : box.map { "New folder in \($0.name)" } ?? "New folder" }
}

/// One folder in the sidebar: its unread count, an arrow to fold its subfolders away, a menu to add or rename
/// folders, and a place to drop conversations.
struct FolderRow: View {
    @EnvironmentObject var store: Store
    let entry: FolderEntry
    let state: AccountState
    @Binding var naming: Naming?
    @State private var targeted = false

    var body: some View {
        let box = entry.box
        HStack(spacing: 2) {
            if entry.hasChildren {
                Button { withAnimation(.snappy) { store.toggleCollapsed(box, in: state) } } label: {
                    Image(systemName: "chevron.right")
                        .font(Look.size(10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(store.isCollapsed(box, in: state) ? 0 : 90))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(store.isCollapsed(box, in: state) ? "Show folders inside \(box.name)" : "Hide folders inside \(box.name)")
            } else {
                Color.clear.frame(width: 14, height: 14)
            }
            Label(box.name, systemImage: box.icon)
        }
        .padding(.leading, CGFloat(entry.depth) * 14)
        .badge(box.showsUnread ? (box.unreadEmails ?? 0) : 0)
        .background(RoundedRectangle(cornerRadius: 6).fill(targeted ? Look.accent.opacity(0.22) : .clear).padding(-4))
        .dropDestination(for: String.self) { ids, _ in
            let result = ids
            Task { _ = await store.drop(result, on: box, in: state) }
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Button { naming = Naming(state: state, box: box, renaming: false) } label: { Label("New folder inside", systemImage: "folder.badge.plus") }
            if box.role == nil {
                Button { naming = Naming(state: state, box: box, renaming: true) } label: { Label("Rename", systemImage: "pencil") }
            }
            if entry.hasChildren {
                Button { store.toggleCollapsed(box, in: state) } label: {
                    store.isCollapsed(box, in: state)
                        ? Label("Show folders inside", systemImage: "chevron.down")
                        : Label("Hide folders inside", systemImage: "chevron.right")
                }
            }
        }
    }
}

// MARK: The list

struct MessageList: View {
    @EnvironmentObject var store: Store
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    let compose: () -> Void

    var body: some View {
        List(selection: $store.selection) {
            ForEach(store.list) { item in
                Row(item: item, showAccount: store.accounts.count > 1 && store.folder == .allInboxes)
                    .tag(item.id)
                    .onDrag { NSItemProvider(object: item.id as NSString) }
                    #if os(iOS)
                    .contextMenu { actions(item) }
                    #endif
                    .swipeActions(edge: .leading) {
                        Button { Task { await store.setUnread(item, !item.email.isUnread) } } label: {
                            Label(item.email.isUnread ? "Read" : "Unread", systemImage: item.email.isUnread ? "envelope.open" : "envelope.badge")
                        }
                        .tint(Look.accent)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { Task { await store.delete(item) } } label: { Label("Delete", systemImage: "trash") }
                        Button { Task { await store.archive(item) } } label: { Label("Archive", systemImage: "archivebox") }
                            .tint(.gray)
                    }
                    .onAppear { if item.id == store.list.last?.id { Task { await store.loadMore() } } }
            }
            if store.list.isEmpty && !store.listLoading {
                Text(store.search.isEmpty ? "Nothing here" : "No emails match")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        #if os(macOS)
        // Right click for actions; double click opens the email in a window of its own.
        .contextMenu(forSelectionType: Item.ID.self) { ids in
            if let item = ids.first.flatMap({ id in store.list.first { $0.id == id } }) { actions(item) }
        } primaryAction: { ids in
            if let item = ids.first.flatMap({ id in store.list.first { $0.id == id } }) {
                openWindow(value: MessageRef(account: item.account.id, email: item.email.id))
            }
        }
        #endif
        .overlay { if store.listLoading && store.list.isEmpty { ProgressView() } }
        .navigationTitle(store.folderTitle)
        #if os(macOS)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $store.search)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await store.reloadList() } }
                    if !store.search.isEmpty {
                        Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 9).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Look.ground))
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
            }
            .background(.bar)
        }
        #else
        .searchable(text: $store.search, prompt: "Search")
        .onSubmit(of: .search) { Task { await store.reloadList() } }
        #endif
        .onChange(of: store.search) { _, words in
            if words.isEmpty { Task { await store.reloadList() } }
        }
        .refreshable { await store.refresh() }
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 520)
        .toolbar {
            ToolbarItem {
                Button { Task { await store.refresh() } } label: { Label("Check for new mail", systemImage: "arrow.clockwise") }
                    .help("Check for new mail")
            }
            ToolbarItem {
                Button(action: compose) { Label("New message", systemImage: "square.and.pencil") }
                    .help("New message (⌘N)")
            }
        }
        #else
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button(action: compose) { Label("New message", systemImage: "square.and.pencil") }
            }
        }
        #endif
    }

    @ViewBuilder private func actions(_ item: Item) -> some View {
        Button { Task { await store.setUnread(item, !item.email.isUnread) } } label: {
            Label(item.email.isUnread ? "Mark as read" : "Mark as unread", systemImage: "envelope.badge")
        }
        Button { Task { await store.flag(item) } } label: {
            Label(item.email.isFlagged ? "Remove star" : "Star", systemImage: item.email.isFlagged ? "star.slash" : "star")
        }
        Divider()
        Button { Task { await store.archive(item) } } label: { Label("Archive", systemImage: "archivebox") }
        MoveMenu(item: item)
        Button(role: .destructive) { Task { await store.delete(item) } } label: { Label("Delete", systemImage: "trash") }
        if store.inSpam(item) {
            Button { Task { await store.markSpam(item, false) } } label: { Label("Not spam", systemImage: "tray.and.arrow.up") }
        } else {
            Button { Task { await store.markSpam(item, true) } } label: { Label("Mark as spam", systemImage: "xmark.bin") }
        }
        #if os(macOS)
        Divider()
        Button { openWindow(value: MessageRef(account: item.account.id, email: item.email.id)) } label: {
            Label("Open in new window", systemImage: "macwindow")
        }
        #endif
    }
}

/// One conversation in the list: who, when, what about, and the first words.
struct Row: View {
    let item: Item
    let showAccount: Bool

    var body: some View {
        let e = item.email
        HStack(alignment: .top, spacing: 11) {
            Avatar(address: e.sender, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if e.isUnread { Circle().fill(Look.accent).frame(width: 7, height: 7).accessibilityLabel("Unread") }
                    Text(e.sender.display)
                        .font(Look.size(15, weight: e.isUnread ? .bold : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if e.isFlagged { Image(systemName: "star.fill").font(.caption2).foregroundStyle(Look.star).accessibilityLabel("Starred") }
                    if e.hasAttachment == true { Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Attachment") }
                    Text(When.short(e.date))
                        .font(Look.size(13, weight: e.isUnread ? .semibold : .regular))
                        .foregroundStyle(e.isUnread ? Look.accent : .secondary)
                }
                Text(e.title)
                    .font(Look.size(14, weight: e.isUnread ? .medium : .regular))
                    .lineLimit(1)
                Text(e.preview ?? "")
                    .font(Look.size(13.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if showAccount {
                    HStack(spacing: 5) { AccountDot(account: item.account, size: 6); Text(item.account.label) }
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

/// Every folder of the item's account, to move a conversation into.
struct MoveMenu: View {
    @EnvironmentObject var store: Store
    let item: Item

    var body: some View {
        Menu {
            if let s = store.state(for: item.account) {
                ForEach(s.tree) { entry in
                    Button(String(repeating: "  ", count: entry.depth) + entry.box.name) {
                        Task { await store.move(item, to: entry.box) }
                    }
                }
            }
        } label: { Label("Move to", systemImage: "folder") }
    }
}

/// The Mac sidebar is see-through glass, which the screenshot picture can't draw, so it's solid in screenshot runs only.
private struct SolidForScreenshots: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        if Demo.launchedForScreens {
            content.scrollContentBackground(.hidden).background(Color(nsColor: .windowBackgroundColor))
        } else {
            content
        }
        #else
        content
        #endif
    }
}
