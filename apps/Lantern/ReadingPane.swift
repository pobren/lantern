// The open conversation: the subject, earlier emails folded into one line each, and the chosen email in full
// with its attachments. The actions sit in the toolbar: reply, reply all, forward, archive, delete, move, star.

import SwiftUI
import QuickLook
import UniformTypeIdentifiers

struct ReadingPane: View {
    @EnvironmentObject var store: Store
    @AppStorage("remoteImages") private var remoteImages = true
    @AppStorage(Trackers.key) private var blockTrackers = true
    @AppStorage(PrivateAI.key) private var aiOn = false
    /// The email with its trackers taken out, worked out once each time the email or the setting changes.
    @State private var cleaned: (html: String, blocked: Int)?
    private var blocked: Int { cleaned?.blocked ?? 0 }
    private var shownHTML: String { cleaned?.html ?? page?.html ?? "" }
    @AppStorage(Store.labelsKey) private var showLabels = false
    let item: Item
    let compose: (ComposeDraft) -> Void

    @State private var thread: [Email] = []
    @State private var open: String?
    @State private var page: (html: String, attachments: [Attachment])?
    @State private var loading = true
    @State private var showImagesOnce = false
    @State private var preview: URL?
    @State private var saving: EmailFile?
    /// Dates, addresses and numbers found in the email (shown above it on the Mac).
    @State private var found: [FoundItem] = []
    @State private var failed = false
    @State private var unsub: Unsubscribe?
    @State private var askingUnsub = false
    @State private var unsubDone: String?
    @State private var waiting: Waiting?
    @State private var cancelled = false
    @Environment(\.openURL) private var openURL

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

            if cancelled {
                Label("Not sent. It's back in Drafts.", systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 22).padding(.bottom, 8)
            } else if let waiting {
                HStack(spacing: 10) {
                    Image(systemName: "clock")
                    Text(waiting.sendAt.map { String(localized: "Sends \($0.formatted(date: .abbreviated, time: .shortened))") } ?? "Waiting to send")
                        .font(.callout)
                    Spacer()
                    Button { editScheduled(waiting) } label: { Label("Edit", systemImage: "pencil") }
                        .buttonStyle(.borderless)
                    Button {
                        Task { if await store.cancelScheduled(shown, waiting: waiting, account: item.account) { cancelled = true } }
                    } label: { Label("Don't send", systemImage: "xmark.circle") }
                        .buttonStyle(.borderless)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22).padding(.bottom, 8)
            }

            if let unsubDone {
                Label(unsubDone, systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 22).padding(.bottom, 8)
            } else if let unsub {
                HStack(spacing: 10) {
                    Image(systemName: "envelope.badge")
                    Text("From a mailing list.").font(.callout)
                    Spacer()
                    Button { askingUnsub = true } label: { Label("Unsubscribe", systemImage: "hand.raised") }
                        .buttonStyle(.borderless)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22).padding(.bottom, 8)
                .confirmationDialog("Unsubscribe from \(shown.sender.display)?", isPresented: $askingUnsub, titleVisibility: .visible) {
                    Button { Task { await leave(unsub) } } label: { Label("Unsubscribe", systemImage: "hand.raised") }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(unsub.oneClick != nil ? "We'll tell the sender to stop, straight away."
                         : unsub.web != nil ? "The sender's unsubscribe page opens in your browser."
                         : "An email asking to unsubscribe opens, ready to send.")
                }
            }

            if aiOn && PrivateAI.available {
                AIEmailTools(email: shown, account: item.account, compose: compose)
                    .padding(.horizontal, 22).padding(.bottom, 8)
            }

            if blockTrackers && blocked > 0 {
                TrackersBlocked(count: blocked)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22).padding(.bottom, 8)
            }

            if !remoteImages && !showImagesOnce && (page != nil && shownHTML.contains("http")) {
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

            #if os(macOS)
            if !found.isEmpty {
                FoundInEmail(items: found, subject: shown.title)
                    .padding(.horizontal, 22).padding(.bottom, 8)
            }
            #endif
            Divider()
            Group {
                if let page {
                    // A white margin around every email, like Apple Mail, even when the email's own styles
                    // take its edges away.
                    EmailWebView(html: cleaned?.html ?? page.html, remoteImages: remoteImages || showImagesOnce)
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
        #if os(macOS)
        .onChange(of: page?.html, initial: true) { _, html in
            found = FoundItem.find(in: String((html.map(EmailText.plain) ?? "").prefix(20_000)))
        }
        #endif
        .onChange(of: page?.html, initial: true) { _, html in cleaned = html.map(Trackers.clean) }
        .onChange(of: blockTrackers) { _, _ in cleaned = page.map { Trackers.clean($0.html) } }
        .background(Look.paper)
        .quickLookPreview($preview)
        .fileExporter(isPresented: Binding(get: { saving != nil }, set: { if !$0 { saving = nil } }),
                      document: saving, contentType: .emailMessage, defaultFilename: EmailFile.name(for: shown)) { _ in saving = nil }
        .toolbar { tools }
        #if os(macOS)
        .touchBar { touchBarButtons }
        #endif
        .focusedSceneValue(\.messageActions, actions)
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

    private func leave(_ u: Unsubscribe) async {
        if let url = u.oneClick {
            do {
                try await JMAPClient.oneClickUnsubscribe(url)
                unsubDone = "Unsubscribed. It can take the sender a few days to stop."
                return
            } catch {
                // The one click address didn't answer: fall back to the page or an email.
            }
        }
        if let url = u.web {
            openURL(url)
            unsubDone = "The unsubscribe page opened in your browser."
        } else if let address = u.mail {
            var d = ComposeDraft.new(store: store)
            d.to = address
            d.subject = "Unsubscribe"
            d.text = "Unsubscribe" + d.text
            compose(d)
        }
    }

    private func load() async {
        loading = true
        page = nil
        failed = false
        showImagesOnce = false
        unsub = nil
        unsubDone = nil
        waiting = nil
        cancelled = false
        let e = shown, account = item.account
        Task { @MainActor in
            let w = await store.waiting(e, account: account)
            if open == e.id || (open == nil && e.id == shown.id) { waiting = w }
        }
        Task { @MainActor in
            let u = await store.unsubscribe(e, account: account)
            if open == e.id || (open == nil && e.id == shown.id) { unsub = u }
        }
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
                .help("Archive (⌃⌘A)")
            Button { Task { await store.delete(item) } } label: { Label("Delete", systemImage: "trash") }
                .help("Delete (⌘⌫)")
            MoveMenu(item: item).help("Move to a folder")
            spamButton
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

    #if os(macOS)
    /// The Touch Bar on MacBook Pros that have one: the everyday actions for the open email.
    @ViewBuilder private var touchBarButtons: some View {
        Button { reply(all: false) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        Button { reply(all: true) } label: { Label("Reply all", systemImage: "arrowshape.turn.up.left.2") }
        Button { forward() } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
        Button { Task { await store.archive(item) } } label: { Label("Archive", systemImage: "archivebox") }
        Button { Task { await store.delete(item) } } label: { Label("Delete", systemImage: "trash") }
        Button { Task { await store.flag(item) } } label: {
            Label(item.email.isFlagged ? "Unstar" : "Star", systemImage: item.email.isFlagged ? "star.slash" : "star")
        }
        Button { Task { await store.markSpam(item, !store.inSpam(item)) } } label: {
            Label(store.inSpam(item) ? "Not spam" : "Spam", systemImage: store.inSpam(item) ? "tray.and.arrow.up" : "xmark.bin")
        }
    }
    #endif

    private var spamButton: some View {
        let spam = store.inSpam(item)
        return Button { Task { await store.markSpam(item, !spam) } } label: {
            Label(spam ? "Not spam" : "Mark as spam", systemImage: spam ? "tray.and.arrow.up" : "xmark.bin")
        }
        .help(spam ? "Not spam: move back to the Inbox (⇧⌘J)" : "Mark as spam (⇧⌘J)")
        #if os(iOS)
        .keyboardShortcut("j", modifiers: [.command, .shift])
        #endif
    }

    @ViewBuilder private var replyButtons: some View {
        if store.isEditableDraft(item, shown) {
            Button { editDraft() } label: { Label("Edit draft", systemImage: "pencil") }
                .help("Carry on writing this draft (⌘E)")
        }
        Button { reply(all: false) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
            .help("Reply (⌘R)")
        Button { reply(all: true) } label: { Label("Reply all", systemImage: "arrowshape.turn.up.left.2") }
            .help("Reply all (⇧⌘R)")
        Button { forward() } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
            .help("Forward (⇧⌘F)")
        #if os(iOS)
        Button { forwardAttached() } label: { Label("Forward as attachment", systemImage: "paperclip") }
        #endif
    }

    /// Everything the Mac's Message menu can do to this email.
    private var actions: MessageActions {
        MessageActions(reply: { reply(all: false) }, replyAll: { reply(all: true) }, forward: { forward() },
                       archive: { Task { await store.archive(item) } }, delete: { Task { await store.delete(item) } },
                       spam: { Task { await store.markSpam(item, !store.inSpam(item)) } },
                       toggleUnread: { Task { await store.setUnread(item, !item.email.isUnread) } },
                       toggleStar: { Task { await store.flag(item) } },
                       editDraft: store.isEditableDraft(item, shown) ? { editDraft() } : nil,
                       inSpam: store.inSpam(item), unread: item.email.isUnread, starred: item.email.isFlagged,
                       mute: { Task { await store.mute(item, !item.email.isMuted) } }, muted: item.email.isMuted,
                       print: { printEmail() }, forwardAttached: { forwardAttached() },
                       moveAgain: store.moveAgainTarget(for: item) == nil ? nil : { Task { await store.moveAgain(item) } },
                       moveAgainName: store.moveAgainTarget(for: item)?.name,
                       addSender: canAddSender ? { addSender() } : nil)
    }

    /// Paul: scheduled emails sit in Scheduled "so you can edit them". Stops the send, then opens it to change,
    /// with the same send time already set. Sending or scheduling it again replaces the copy in Drafts.
    private func editScheduled(_ w: Waiting) {
        let e = shown
        Task {
            let text = await store.text(e, account: item.account)
            let files = page?.attachments ?? []
            guard await store.cancelScheduled(e, waiting: w, account: item.account) else { return }
            cancelled = true
            var d = ComposeDraft.editing(e, account: item.account, text: text, attachments: files, store: store)
            d.sendAt = w.sendAt
            compose(d)
        }
    }

    /// Opens a saved draft for writing again; saving or sending it replaces the old copy.
    private func editDraft() {
        let e = shown
        Task {
            let text = await store.text(e, account: item.account)
            let files = page?.attachments ?? []
            compose(ComposeDraft.editing(e, account: item.account, text: text, attachments: files, store: store))
        }
    }

    private var more: some View {
        Menu {
            Button { Task { await store.flag(item) } } label: {
                Label(item.email.isFlagged ? "Remove star" : "Star", systemImage: item.email.isFlagged ? "star.slash" : "star")
            }
            Button { Task { await store.setUnread(item, true) } } label: { Label("Mark as unread", systemImage: "envelope.badge") }
            if let again = store.moveAgainTarget(for: item) {
                Button { Task { await store.moveAgain(item) } } label: { Label("Move again to \(again.name)", systemImage: "folder.badge.plus") }
                    .help("Move again (⌥⌘T)")
            }
            #if os(macOS)
            Button { forwardAttached() } label: { Label("Forward as attachment", systemImage: "paperclip") }
            #endif
            if canAddSender {
                Button { addSender() } label: { Label("Add sender to Contacts", systemImage: "person.crop.circle.badge.plus") }
            }
            Button { Task { await store.mute(item, !item.email.isMuted) } } label: {
                Label(item.email.isMuted ? "Unmute conversation" : "Mute conversation",
                      systemImage: item.email.isMuted ? "bell" : "bell.slash")
            }
            .help(item.email.isMuted ? "Let replies to this conversation into the inbox again" : "Replies to this conversation skip the inbox (⇧⌘M)")
            // Folders (Fastmail's default) move mail with the folder button; Labels only when turned on in Settings.
            if showLabels { Menu {
                ForEach(store.labels(for: item)) { entry in
                    let on = item.email.mailboxIds[entry.box.id] == true
                    Button { Task { await store.setLabel(item, entry.box, on: !on) } } label: {
                        Label(String(repeating: "  ", count: entry.depth) + entry.box.name, systemImage: on ? "checkmark" : "tag")
                    }
                }
            } label: { Label("Labels", systemImage: "tag") } }
            #if os(iOS)
            spamButton
            #endif
            Divider()
            ShareLink(item: EmailText.forSharing(shown, html: page?.html), subject: Text(shown.title)) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            Button { printEmail() } label: { Label("Print…", systemImage: "printer") }
            Button { save() } label: { Label("Save as…", systemImage: "square.and.arrow.down") }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        } label: { Label("More", systemImage: "ellipsis.circle") }
    }

    private func printEmail() {
        EmailPrinter.print(shown, html: page.map { _ in shownHTML } ?? EmailWebView.plain(shown.preview ?? ""), remoteImages: remoteImages || showImagesOnce)
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

    /// Contacts need an account with Contacts access, and a sender with an address.
    private var canAddSender: Bool {
        !shown.sender.email.isEmpty && (store.state(for: item.account)?.client.canContacts ?? false)
    }

    private func addSender() {
        let who = shown.sender
        AddContactRequest(name: who.name ?? "", email: who.email, account: item.account.id).post()
    }

    private func forwardAttached() {
        let e = shown
        Task { if let d = await ComposeDraft.forwardAsAttachment(e, account: item.account, store: store) { compose(d) } }
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
        // The .eml goes on the name itself: left to the save panel, the Mac saved it with no extension, so Finder
        // couldn't tell it was an email (Paul, 20 Nov 2026). Long subjects are kept whole up to 200 characters.
        let base = String((clean.isEmpty ? "Email" : clean).prefix(200)).trimmingCharacters(in: .whitespaces)
        return base + ".eml"
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
