// The open conversation: the subject, earlier emails folded into one line each, and the chosen email in full
// with its attachments. The actions sit in the toolbar: reply, reply all, forward, archive, delete, move, star.

import SwiftUI
import QuickLook

struct ReadingPane: View {
    @EnvironmentObject var store: Store
    @AppStorage("remoteImages") private var remoteImages = true
    let item: Item
    let compose: (ComposeDraft) -> Void

    @State private var thread: [Email] = []
    @State private var open: String?
    @State private var page: (html: String, attachments: [Attachment])?
    @State private var loading = true
    @State private var showImagesOnce = false
    @State private var preview: URL?

    private var shown: Email { thread.first { $0.id == open } ?? thread.last ?? item.email }
    private var earlier: [Email] { thread.filter { $0.id != shown.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.email.title)
                .font(.system(size: 21, weight: .semibold))
                .textSelection(.enabled)
                .lineLimit(3)
                .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 10)

            if !earlier.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(earlier) { e in
                            Button { choose(e) } label: { Folded(email: e) }
                                .buttonStyle(.plain)
                            Divider().padding(.leading, 22)
                        }
                    }
                }
                .frame(maxHeight: 190)
                .fixedSize(horizontal: false, vertical: earlier.count < 4)
            }

            Header(email: shown, account: item.account)
                .padding(.horizontal, 22).padding(.vertical, 12)

            if let files = page?.attachments, !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(files) { a in
                            Button { Task { preview = await store.file(a, account: item.account) } } label: {
                                Label { (Text("\(a.name)  ") + Text(a.sizeText).foregroundColor(.secondary)).lineLimit(1) }
                                    icon: { Image(systemName: a.icon) }
                                    .font(.system(size: 12.5))
                                    .padding(.horizontal, 10).frame(height: 30)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Look.ground))
                            }
                            .buttonStyle(.plain)
                            .help("Open \(a.name)")
                        }
                    }
                    .padding(.horizontal, 22)
                }
                .padding(.bottom, 10)
            }

            if !remoteImages && !showImagesOnce && (page?.html.contains("http") ?? false) {
                HStack(spacing: 10) {
                    Image(systemName: "eye.slash")
                    Text("Pictures from the web are hidden.").font(.callout)
                    Spacer()
                    Button { showImagesOnce = true } label: { Label("Show pictures", systemImage: "photo") }
                        .buttonStyle(.borderless)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22).padding(.bottom, 8)
            }

            Divider()
            Group {
                if let page {
                    EmailWebView(html: page.html, remoteImages: remoteImages || showImagesOnce)
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        Text(shown.preview ?? "").font(.system(size: 15)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
        }
        .background(Look.paper)
        .quickLookPreview($preview)
        .toolbar { tools }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            thread = await store.conversation(item)
            open = thread.last?.id
            await load()
            await store.markRead(thread, account: item.account)
        }
    }

    private func choose(_ e: Email) {
        open = e.id
        Task { await load() }
    }

    private func load() async {
        loading = true
        page = nil
        showImagesOnce = false
        page = await store.page(shown, account: item.account)
        loading = false
    }

    // MARK: Actions

    @ToolbarContentBuilder private var tools: some ToolbarContent {
        #if os(macOS)
        ToolbarItemGroup {
            replyButtons
            Divider()
            Button { Task { await store.archive(item) } } label: { Label("Archive", systemImage: "archivebox") }
                .help("Archive (⌃⌘A)").keyboardShortcut("a", modifiers: [.command, .control])
            Button { Task { await store.delete(item) } } label: { Label("Delete", systemImage: "trash") }
                .help("Delete (⌘⌫)").keyboardShortcut(.delete, modifiers: .command)
            MoveMenu(item: item).help("Move to a folder")
            more
        }
        #else
        ToolbarItemGroup(placement: .bottomBar) {
            Button { Task { await store.archive(item) } } label: { Label("Archive", systemImage: "archivebox") }
            Spacer()
            Button { Task { await store.delete(item) } } label: { Label("Delete", systemImage: "trash") }
            Spacer()
            MoveMenu(item: item)
            Spacer()
            Menu { replyButtons } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        }
        ToolbarItem(placement: .topBarTrailing) { more }
        #endif
    }

    @ViewBuilder private var replyButtons: some View {
        Button { reply(all: false) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
            .help("Reply (⌘R)").keyboardShortcut("r", modifiers: .command)
        Button { reply(all: true) } label: { Label("Reply all", systemImage: "arrowshape.turn.up.left.2") }
            .help("Reply all (⇧⌘R)").keyboardShortcut("r", modifiers: [.command, .shift])
        Button { forward() } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
            .help("Forward (⇧⌘F)").keyboardShortcut("f", modifiers: [.command, .shift])
    }

    private var more: some View {
        Menu {
            Button { Task { await store.flag(item) } } label: {
                Label(item.email.isFlagged ? "Remove star" : "Star", systemImage: item.email.isFlagged ? "star.slash" : "star")
            }
            Button { Task { await store.setUnread(item, true) } } label: { Label("Mark as unread", systemImage: "envelope.badge") }
        } label: { Label("More", systemImage: "ellipsis.circle") }
    }

    private func reply(all: Bool) {
        let e = shown
        Task {
            let text = await store.text(e, account: item.account)
            compose(ComposeDraft.reply(to: e, account: item.account, all: all, quoting: text, store: store))
        }
    }

    private func forward() {
        let e = shown
        Task {
            let text = await store.text(e, account: item.account)
            compose(ComposeDraft.forward(e, account: item.account, quoting: text, store: store))
        }
    }
}

/// An earlier email in the conversation, folded to one line until you open it.
private struct Folded: View {
    let email: Email
    var body: some View {
        HStack(spacing: 10) {
            Avatar(address: email.sender, size: 26)
            Text(email.sender.display).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text(email.preview ?? "").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Text(When.short(email.date)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22).padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

/// Who sent the email, to whom, and when.
private struct Header: View {
    let email: Email
    let account: Account
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(address: email.sender, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(email.sender.display).font(.system(size: 14, weight: .semibold))
                    Text(email.sender.email).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                .textSelection(.enabled)
                if let to = email.to, !to.isEmpty {
                    Text("To " + to.map(\.display).joined(separator: ", ")).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                if let cc = email.cc, !cc.isEmpty {
                    Text("Cc " + cc.map(\.display).joined(separator: ", ")).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(When.long(email.date)).font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 5) { AccountDot(account: account, size: 6); Text(account.label) }
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }
}
