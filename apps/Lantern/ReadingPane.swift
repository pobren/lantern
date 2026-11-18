// The open conversation: the subject, earlier emails folded into one line each, and the chosen email in full
// with its attachments. The actions sit in the toolbar: reply, reply all, forward, archive, delete, move, star.

import SwiftUI
import QuickLook
import UniformTypeIdentifiers

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
    @State private var saving: EmailFile?
    @State private var failed = false

    private var shown: Email { thread.first { $0.id == open } ?? thread.last ?? item.email }
    private var earlier: [Email] { thread.filter { $0.id != shown.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.email.title)
                    .font(Look.size(21, weight: .semibold))
                    .textSelection(.enabled)
                    .lineLimit(3)
                Spacer(minLength: 8)
                Button { Task { await store.flag(item) } } label: {
                    Image(systemName: item.email.isFlagged ? "star.fill" : "star")
                        .font(Look.size(17))
                        .foregroundStyle(item.email.isFlagged ? Look.star : .secondary)
                }
                .buttonStyle(.borderless)
                .help(item.email.isFlagged ? "Remove star" : "Star")
                .accessibilityLabel(item.email.isFlagged ? "Remove star" : "Star")
            }
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
                                    .font(Look.size(12.5))
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
                    // A white margin around every email, like Apple Mail, even when the email's own styles
                    // take its edges away.
                    EmailWebView(html: page.html, remoteImages: remoteImages || showImagesOnce)
                        #if os(macOS)
                        .padding(.horizontal, 24).padding(.top, 10)
                        #else
                        .padding(.horizontal, 10).padding(.top, 4)
                        #endif
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(shown.preview ?? "").font(Look.size(15)).textSelection(.enabled)
                            if failed {
                                Text("Couldn't load the whole email.").font(Look.size(13)).foregroundStyle(.secondary)
                                Button { Task { await load() } } label: { Label("Try again", systemImage: "arrow.clockwise") }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
        }
        .background(Look.paper)
        .quickLookPreview($preview)
        .fileExporter(isPresented: Binding(get: { saving != nil }, set: { if !$0 { saving = nil } }),
                      document: saving, contentType: .emailMessage, defaultFilename: EmailFile.name(for: shown)) { _ in saving = nil }
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
        failed = false
        showImagesOnce = false
        let e = shown, account = item.account
        // Fetched outside this view's task, so a list refresh that redraws the view can't cancel it halfway
        // and leave only the preview line showing. Tried twice before giving up.
        page = await Task { @MainActor () -> (html: String, attachments: [Attachment])? in
            for attempt in 0..<2 {
                if let p = await store.page(e, account: account) { return p }
                if attempt == 0 { try? await Task.sleep(nanoseconds: 600_000_000) }
            }
            return nil
        }.value
        if page == nil, open == e.id {
            // Still nothing: show the whole plain text rather than just the preview line.
            let text = await store.text(e, account: account)
            if !text.isEmpty, text != e.preview { page = (EmailWebView.plain(text), []) } else { failed = true }
        }
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
            Divider()
            Button { save() } label: { Label("Save as…", systemImage: "square.and.arrow.down") }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        } label: { Label("More", systemImage: "ellipsis.circle") }
    }

    /// Saves the email exactly as it arrived, as an .eml file any mail app can open.
    private func save() {
        let e = shown
        Task { if let data = await store.original(e, account: item.account) { saving = EmailFile(data: data) } }
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
            Text(email.sender.display).font(Look.size(13, weight: .medium)).lineLimit(1)
            Text(email.preview ?? "").font(Look.size(13)).foregroundStyle(.secondary).lineLimit(1)
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
            Avatar(address: email.sender, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                // Name and date share the top line; the address sits underneath, so a long name never
                // gets squeezed into a narrow column on iPhone.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(email.sender.display).font(Look.size(14, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 6)
                    Text(When.long(email.date)).font(Look.size(12)).foregroundStyle(.secondary).lineLimit(1)
                        .layoutPriority(1)
                }
                Text(email.sender.email).font(Look.size(12.5)).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle)
                if let to = email.to, !to.isEmpty {
                    Text("To " + to.map(\.display).joined(separator: ", ")).font(Look.size(12.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                if let cc = email.cc, !cc.isEmpty {
                    Text("Cc " + cc.map(\.display).joined(separator: ", ")).font(Look.size(12.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 5) { AccountDot(account: account, size: 6); Text(account.label) }
                    .font(Look.size(11.5)).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
        }
    }
}

/// An email as a file (.eml), for Save as.
struct EmailFile: FileDocument {
    static var readableContentTypes: [UTType] { [.emailMessage] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }

    /// The subject, made safe for a file name.
    static func name(for e: Email) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let clean = e.title.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return String((clean.isEmpty ? "Email" : clean).prefix(80))
    }
}

/// An email in a window of its own (double click it in the list on Mac).
struct MessageWindow: View {
    @EnvironmentObject var store: Store
    let ref: MessageRef
    @State private var fetched: Item?
    @State private var composing: ComposeDraft?
    @State private var missing = false

    /// The live copy from the list when there is one, so stars and read marks stay in step with the main window.
    private var item: Item? {
        store.list.first { $0.account.id == ref.account && $0.email.id == ref.email } ?? fetched
    }

    var body: some View {
        NavigationStack {
            if let item {
                ReadingPane(item: item, compose: { composing = $0 })
            } else if missing {
                Text("This email isn't there any more.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(item?.email.title ?? "Email")
        .sheet(item: $composing) { draft in ComposeView(draft: draft).environmentObject(store) }
        .task {
            if item == nil {
                fetched = await store.item(ref)
                missing = fetched == nil
            }
        }
    }
}
