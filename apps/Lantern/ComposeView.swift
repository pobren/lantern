// Writing a new email, a reply, a reply to all or a forward, from any of your addresses on any account.

import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

struct ComposeDraft: Identifiable {
    let id = UUID()
    var account: Account?
    var identityId: String?
    /// The exact address to send as, when the identity covers a whole domain (*@example.com).
    var fromEmail = ""
    /// The address the email being answered was sent to, when none of your sending addresses covers it yet.
    var unmatched: String?
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var text = ""
    var replyTo: Email?
    /// The saved draft this was opened from, so saving again or sending replaces it rather than leaving a copy.
    var draftId: String?
    /// Threading headers carried over from a saved draft that was a reply.
    var savedThreading: (inReplyTo: String?, references: [String])?
    /// Files already on a saved draft.
    var attachments: [Outgoing] = []

    var threading: (inReplyTo: String?, references: [String]) { savedThreading ?? Store.threading(replyTo) }

    /// "-- " and the signature, the standard way, so other mail apps know where it starts.
    static func signed(_ signature: String) -> String {
        signature.isEmpty ? "" : "-- \n" + signature
    }

    @MainActor static func new(store: Store) -> ComposeDraft {
        var s = store.accounts.first
        if case .mailbox(let a, _) = store.folder { s = store.state(id: a) ?? s }
        let identity = s.flatMap { store.defaultIdentity($0) }
        let sig = identity.map { signed(store.signature(for: $0)) } ?? ""
        return ComposeDraft(account: s?.account, identityId: identity?.id, text: sig.isEmpty ? "" : "\n\n" + sig)
    }

    @MainActor static func reply(to e: Email, account: Account, all: Bool, quoting text: String, store: Store) -> ComposeDraft {
        let s = store.state(for: account)
        let mine = Set(((s?.identities ?? []).map(\.email) + [account.username]).map { $0.lowercased() })
        let wroteTo = (e.to ?? []) + (e.cc ?? [])
        let ids = s?.identities ?? []
        // Answer from the address it was sent to: an exact match first, then a whole-domain identity.
        var fromEmail = ""
        var identity = ids.first { id in !id.isWildcard && wroteTo.contains { id.covers($0.email) } }
        if identity == nil {
            for a in wroteTo {
                if let w = ids.first(where: { $0.isWildcard && $0.covers(a.email) }) { identity = w; fromEmail = a.email; break }
            }
        }
        // Sent to an address of yours (an alias, say) that isn't set up for sending yet: offer to add it.
        // Only your own domains count: shared ones like fastmail.com belong to everyone.
        let ownDomains = Set(ids.map(\.domain).filter { d in
            !(d.hasPrefix("fastmail.") || d.hasPrefix("messagingengine.") || ["sent.com", "gmail.com", "icloud.com", "outlook.com"].contains(d))
        })
        let unmatched = identity == nil
            ? wroteTo.first { a in ownDomains.contains(a.email.split(separator: "@").last.map { String($0).lowercased() } ?? "") }?.email
            : nil
        if identity == nil { identity = s.flatMap { store.defaultIdentity($0) } }
        let fromMe = mine.contains(e.sender.email.lowercased())
        let answer = fromMe ? (e.to ?? []) : (e.replyTo?.isEmpty == false ? e.replyTo! : [e.sender])
        var cc: [EmailAddress] = []
        if all {
            let taken = Set(answer.map { $0.email.lowercased() }).union(mine)
            var seen = Set<String>()
            cc = wroteTo.filter { a in
                let key = a.email.lowercased()
                return !taken.contains(key) && seen.insert(key).inserted
            }
        }
        let title = e.title
        return ComposeDraft(account: account, identityId: identity?.id, fromEmail: fromEmail, unmatched: unmatched,
                            to: answer.map(\.full).joined(separator: ", "),
                            cc: cc.map(\.full).joined(separator: ", "),
                            subject: title.lowercased().hasPrefix("re:") ? title : "Re: \(title)",
                            text: "\n\n" + block(identity, store) + quote(e, text),
                            replyTo: e)
    }

    @MainActor static func forward(_ e: Email, account: Account, quoting text: String, store: Store) -> ComposeDraft {
        let s = store.state(for: account)
        let title = e.title
        let header = [
            "---------- Forwarded message ----------",
            "From: \(e.sender.full)",
            "Date: \(When.long(e.date))",
            "Subject: \(title)",
            "To: \((e.to ?? []).map(\.full).joined(separator: ", "))"
        ].joined(separator: "\n")
        let identity = s.flatMap { store.defaultIdentity($0) }
        return ComposeDraft(account: account, identityId: identity?.id,
                            subject: title.lowercased().hasPrefix("fwd:") ? title : "Fwd: \(title)",
                            text: "\n\n" + block(identity, store) + header + "\n\n" + text)
    }

    /// Picks a saved draft up again, with its addresses, words and files.
    @MainActor static func editing(_ e: Email, account: Account, text: String, attachments: [Attachment], store: Store) -> ComposeDraft {
        let ids = store.state(for: account)?.identities ?? []
        let from = e.from?.first?.email ?? ""
        var fromEmail = ""
        var identity = ids.first { !$0.isWildcard && $0.email.lowercased() == from.lowercased() }
        if identity == nil, let w = ids.first(where: { $0.isWildcard && $0.covers(from) }) { identity = w; fromEmail = from }
        if identity == nil { identity = store.state(for: account).flatMap { store.defaultIdentity($0) } }
        return ComposeDraft(account: account, identityId: identity?.id, fromEmail: fromEmail,
                            to: (e.to ?? []).map(\.full).joined(separator: ", "),
                            cc: (e.cc ?? []).map(\.full).joined(separator: ", "),
                            bcc: (e.bcc ?? []).map(\.full).joined(separator: ", "),
                            subject: e.subject ?? "", text: text, draftId: e.id,
                            savedThreading: (e.inReplyTo?.first, e.references ?? []),
                            attachments: attachments.map { Outgoing(blobId: $0.blobId, name: $0.name, type: $0.type, size: $0.size) })
    }

    /// The signature followed by a blank line, or nothing if there isn't one.
    @MainActor private static func block(_ identity: Identity?, _ store: Store) -> String {
        guard let identity else { return "" }
        let sig = signed(store.signature(for: identity))
        return sig.isEmpty ? "" : sig + "\n\n"
    }

    /// "On Wed 18 Nov 2026 at 10:47, Maya Chen wrote:" and the email below it, each line marked with >.
    private static func quote(_ e: Email, _ text: String) -> String {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }
        return "On \(When.long(e.date)), \(e.sender.display) wrote:\n" + lines.joined(separator: "\n")
    }
}

struct ComposeView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var draft: ComposeDraft
    @State private var showCc = false
    @State private var showBcc = false
    @State private var sending = false
    @State private var problem: String?
    @FocusState private var focus: Field?
    @State private var files: [Outgoing] = []
    @State private var uploading = 0
    @State private var picking = false
    /// What the email looked like when it opened, to tell whether closing it would lose anything.
    @State private var start = ""
    @State private var askingToClose = false
    @State private var savingDraft = false
    #if os(iOS)
    @State private var photos: [PhotosPickerItem] = []
    #endif

    private enum Field { case to, cc, bcc, body }
    /// When to send, for Send later. Nil sends now.
    @State private var sendAt: Date?
    @State private var pickingTime = false
    @State private var pickedTime = Date().addingTimeInterval(3600)

    init(draft: ComposeDraft) {
        _draft = State(initialValue: draft)
        _showCc = State(initialValue: !draft.cc.isEmpty)
        _showBcc = State(initialValue: !draft.bcc.isEmpty)
        _files = State(initialValue: draft.attachments)
        _start = State(initialValue: Self.snapshot(draft, draft.attachments))
    }

    private static func snapshot(_ d: ComposeDraft, _ files: [Outgoing]) -> String {
        [d.to, d.cc, d.bcc, d.subject, d.text, files.map(\.blobId).joined(separator: ",")].joined(separator: "\u{1}")
    }

    /// Something has been written or changed since the email opened.
    private var changed: Bool { Self.snapshot(draft, files) != start }

    /// Closing asks first when there's something to lose: keep it in Drafts, throw it away, or carry on writing.
    private func close() {
        if changed { askingToClose = true } else { dismiss() }
    }

    private func saveAndClose() async {
        guard let account = draft.account, let s = store.state(for: account),
              let identity = s.identities.first(where: { $0.id == draft.identityId }) else { problem = "Choose who it's from first."; return }
        savingDraft = true; problem = nil
        do {
            let address = identity.isWildcard && !draft.fromEmail.isEmpty ? draft.fromEmail.trimmingCharacters(in: .whitespaces) : nil
            try await store.saveDraft(account: account, identity: identity, as: address, to: EmailAddress.parse(draft.to),
                                      cc: EmailAddress.parse(draft.cc), bcc: EmailAddress.parse(draft.bcc), subject: draft.subject, text: draft.text,
                                      threading: draft.threading, attachments: files, replacing: draft.draftId)
            dismiss()
        } catch {
            problem = "Couldn't save the draft: \(error.localizedDescription)"
        }
        savingDraft = false
    }

    @ViewBuilder private var closeChoices: some View {
        Button("Save to Drafts") { Task { await saveAndClose() } }
        Button(draft.draftId == nil ? "Delete" : "Discard changes", role: .destructive) { dismiss() }
        Button("Keep writing", role: .cancel) {}
    }

    /// Every address you can send from, across every account.
    private var choices: [(Account, Identity)] {
        store.accounts.flatMap { s in s.identities.map { (s.account, $0) } }
    }

    private var chosenKey: Binding<String> {
        Binding(
            get: { "\(draft.account?.id ?? "")|\(draft.identityId ?? "")" },
            set: { key in
                let parts = key.split(separator: "|").map(String.init)
                guard parts.count == 2 else { return }
                let old = identity(draft.account, draft.identityId).map { ComposeDraft.signed(store.signature(for: $0)) } ?? ""
                draft.account = store.accounts.first { $0.id == parts[0] }?.account
                draft.identityId = parts[1]
                let new = identity(draft.account, draft.identityId).map { ComposeDraft.signed(store.signature(for: $0)) } ?? ""
                if !old.isEmpty, draft.text.contains(old) {
                    draft.text = draft.text.replacingOccurrences(of: old, with: new)
                } else if old.isEmpty, !new.isEmpty, draft.replyTo == nil, draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    draft.text = "\n\n" + new
                }
            })
    }

    private func identity(_ account: Account?, _ id: String?) -> Identity? {
        guard let account, let s = store.state(for: account) else { return nil }
        return s.identities.first { $0.id == id }
    }

    private var chosen: Identity? { identity(draft.account, draft.identityId) }

    /// A whole-domain identity needs the exact address typed in, at that domain.
    private var fromOK: Bool {
        guard let id = chosen, id.isWildcard else { return true }
        let a = draft.fromEmail.trimmingCharacters(in: .whitespaces)
        return a.contains("@") && id.covers(a) && !a.contains(" ")
    }

    private var canSend: Bool {
        !(EmailAddress.parse(draft.to) + EmailAddress.parse(draft.bcc)).isEmpty && draft.account != nil && draft.identityId != nil && fromOK && !sending && uploading == 0
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Text(title).font(Look.size(15, weight: .semibold))
                Spacer()
                Button { close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction).accessibilityLabel("Close")
            }
            .padding(.horizontal, 20).frame(height: 48)
            Divider()
            form
            Divider()
            HStack {
                if let problem { Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red).lineLimit(2) }
                Button { picking = true } label: { Label("Attach", systemImage: "paperclip") }
                    .buttonStyle(.borderless)
                    .help("Attach files (⇧⌘A)")
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Spacer()
                Text("⌘↩ to send").font(.caption).foregroundStyle(.secondary)
                sendButton.buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20).frame(height: 54)
        }
        .frame(width: 680, height: 580)
        .background(Look.paper)
        .onAppear { focus = draft.to.isEmpty ? .to : .body }
        .task { for s in store.accounts { await s.loadContacts() } }
        .confirmationDialog("Save this email to Drafts?", isPresented: $askingToClose, titleVisibility: .visible) { closeChoices }
            message: { Text("You can pick it up again from your Drafts folder.") }
        .interactiveDismissDisabled(changed)
        .disabled(savingDraft)
        .focusedSceneValue(\.composing, true)
        #else
        NavigationStack {
            VStack(spacing: 0) {
                form
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red).padding()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { close() } }
                ToolbarItem(placement: .confirmationAction) { sendButton }
                ToolbarItemGroup(placement: .bottomBar) {
                    PhotosPicker(selection: $photos, matching: .any(of: [.images, .videos])) {
                        Label("Photos", systemImage: "photo")
                    }
                    Button { picking = true } label: { Label("Files", systemImage: "paperclip") }
                    Spacer()
                }
            }
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                photos = []
                Task { for item in items { await addPhoto(item) } }
            }
        }
        .onAppear { focus = draft.to.isEmpty ? .to : .body }
        .task { for s in store.accounts { await s.loadContacts() } }
        .confirmationDialog("Save this email to Drafts?", isPresented: $askingToClose, titleVisibility: .visible) { closeChoices }
            message: { Text("You can pick it up again from your Drafts folder.") }
        .interactiveDismissDisabled(changed)
        .disabled(savingDraft)
        .focusedSceneValue(\.composing, true)
        #endif
    }

    private var title: String {
        if draft.replyTo != nil { return "Reply" }
        if draft.subject.hasPrefix("Fwd:") { return "Forward" }
        return "New message"
    }

    private var sendButton: some View {
        HStack(spacing: 8) {
            if canSendLater { laterMenu }
            Button { Task { await send() } } label: {
                if sending { ProgressView().controlSize(.small) }
                else if sendAt != nil { Label("Schedule", systemImage: "clock.badge.checkmark") }
                else { Label("Send", systemImage: "paperplane") }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSend)
        }
        .sheet(isPresented: $pickingTime) { timePicker }
    }

    // MARK: Send later

    /// Fastmail holds the email and sends it at the time chosen. Shown only when the server says it can.
    private var canSendLater: Bool {
        guard let account = draft.account, let s = store.state(for: account) else { return false }
        return s.client.maxDelayedSend > 0
    }

    private var laterLimit: Date {
        guard let account = draft.account, let s = store.state(for: account) else { return Date() }
        return Date().addingTimeInterval(TimeInterval(s.client.maxDelayedSend))
    }

    private var laterMenu: some View {
        Menu {
            ForEach(Self.laterChoices(), id: \.1) { name, date in
                if date <= laterLimit {
                    Button { sendAt = date } label: { Label(name, systemImage: "clock") }
                }
            }
            Button { pickedTime = sendAt ?? Date().addingTimeInterval(3600); pickingTime = true } label: {
                Label("Choose a time", systemImage: "calendar")
            }
            if sendAt != nil {
                Button { sendAt = nil } label: { Label("Send now instead", systemImage: "paperplane") }
            }
        } label: {
            Label("Send later", systemImage: "clock")
        }
        .help("Send later")
        #if os(macOS)
        .menuStyle(.borderlessButton).fixedSize()
        #endif
    }

    /// Later today, this evening, tomorrow morning and Monday morning, whichever are still ahead.
    static func laterChoices(now: Date = Date()) -> [(String, Date)] {
        let cal = Calendar.current
        func at(_ day: Date, _ hour: Int) -> Date { cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day }
        var out: [(String, Date)] = []
        let inHour = now.addingTimeInterval(3600)
        out.append(("In an hour", inHour))
        let evening = at(now, 18)
        if evening > inHour { out.append(("This evening at 6pm", evening)) }
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
        out.append(("Tomorrow at 8am", at(tomorrow, 8)))
        if let monday = cal.nextDate(after: now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime),
           !cal.isDate(monday, inSameDayAs: tomorrow) {
            out.append(("Monday at 8am", at(monday, 8)))
        }
        return out
    }

    private var timePicker: some View {
        NavigationStack {
            Form {
                DatePicker("Send at", selection: $pickedTime, in: Date().addingTimeInterval(120)...laterLimit)
                    #if os(iOS)
                    .datePickerStyle(.graphical)
                    #endif
                Text("Fastmail keeps the email and sends it then, even if this device is off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle("Send later")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { sendAt = pickedTime; pickingTime = false } label: { Label("Set time", systemImage: "checkmark") }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button { pickingTime = false } label: { Label("Cancel", systemImage: "xmark") }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 300)
        #endif
    }

    // MARK: Contacts

    private func text(_ field: Field) -> Binding<String> {
        switch field {
        case .cc: return $draft.cc
        case .bcc: return $draft.bcc
        default: return $draft.to
        }
    }

    /// People matching what's being typed after the last comma, from Fastmail contacts and the inbox.
    private func matches(_ field: Field) -> [Contact] {
        let typed = text(field).wrappedValue.split(separator: ",", omittingEmptySubsequences: false).last
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard typed.count >= 2, !typed.contains("<") else { return [] }
        let already = Set(EmailAddress.parse(draft.to + "," + draft.cc + "," + draft.bcc).map { $0.email.lowercased() })
        let all = store.accounts.flatMap(\.contacts)
        var seen = Set<String>()
        return all.filter { c in
            !already.contains(c.id) && seen.insert(c.id).inserted
                && (c.email.lowercased().hasPrefix(typed) || c.name.lowercased().split(separator: " ").contains { $0.hasPrefix(typed) }
                    || c.name.lowercased().hasPrefix(typed))
        }
        .prefix(5).map { $0 }
    }

    @ViewBuilder private func suggestions(_ field: Field) -> some View {
        let found = matches(field)
        if !found.isEmpty {
            VStack(spacing: 0) {
                ForEach(found) { c in
                    Button { pick(c, field) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                if !c.name.isEmpty { Text(c.name).font(Look.size(14)) }
                                Text(c.email).font(Look.size(12.5)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 20).padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
                Divider().padding(.leading, 20)
            }
            .background(Look.ground.opacity(0.5))
        }
    }

    private func pick(_ c: Contact, _ field: Field) {
        var parts = text(field).wrappedValue.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if !parts.isEmpty { parts.removeLast() }
        parts.append(c.line)
        text(field).wrappedValue = parts.filter { !$0.isEmpty }.joined(separator: ", ") + ", "
    }

    private func pickFirst(_ field: Field) {
        if let first = matches(field).first { pick(first, field) }
    }

    private var form: some View {
        VStack(spacing: 0) {
            if let address = draft.unmatched, let account = draft.account {
                HStack(spacing: 10) {
                    Image(systemName: "at").foregroundStyle(.secondary)
                    Text("Sent to \(address), which isn't set up for sending.").font(Look.size(12.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task {
                            do {
                                if let made = try await store.addIdentity(address, account: account) {
                                    chosenKey.wrappedValue = "\(account.id)|\(made.id)"
                                }
                                draft.unmatched = nil
                            } catch {
                                problem = "Couldn't add \(address): \(error.localizedDescription)"
                            }
                        }
                    } label: { Label("Reply from it", systemImage: "plus.circle") }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 20).frame(minHeight: 38)
                Divider().padding(.leading, 20)
            }
            if choices.count > 1 || chosen?.isWildcard == true {
                row("From") {
                    Picker("From", selection: chosenKey) {
                        ForEach(choices.indices, id: \.self) { i in
                            let (account, identity) = choices[i]
                            Text(store.accounts.count > 1 ? "\(identity.label), \(account.label)" : identity.label)
                                .tag("\(account.id)|\(identity.id)")
                        }
                    }
                    .labelsHidden()
                    Spacer()
                }
            }
            if let id = chosen, id.isWildcard {
                row("As") {
                    TextField("you@\(id.domain)", text: $draft.fromEmail)
                        .textFieldStyle(.plain)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    if !draft.fromEmail.isEmpty && !fromOK {
                        Text("Must end @\(id.domain)").font(Look.size(12)).foregroundStyle(.red)
                    }
                }
            }
            row("To") {
                TextField("", text: $draft.to)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .to)
                    .onSubmit { pickFirst(.to) }
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                if !showCc { Button("Cc") { showCc = true }.buttonStyle(.borderless) }
                if !showBcc { Button("Bcc") { showBcc = true }.buttonStyle(.borderless) }
            }
            if focus == .to { suggestions(.to) }
            if showCc {
                row("Cc") {
                    TextField("", text: $draft.cc)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .cc)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
            }
            if showCc && focus == .cc { suggestions(.cc) }
            if showBcc {
                row("Bcc") {
                    TextField("", text: $draft.bcc)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .bcc)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
            }
            if showBcc && focus == .bcc { suggestions(.bcc) }
            if let sendAt {
                HStack(spacing: 10) {
                    Image(systemName: "clock").foregroundStyle(Look.accent)
                    Text("Sends \(When.long(sendAt))").font(Look.size(13))
                    Spacer()
                    Button { self.sendAt = nil } label: { Label("Send now instead", systemImage: "xmark.circle") }
                        .buttonStyle(.borderless).font(Look.size(13))
                }
                .padding(.horizontal, 20).frame(minHeight: 38)
                Divider().padding(.leading, 20)
            }
            row("Subject") { TextField("", text: $draft.subject).textFieldStyle(.plain) }
            if !files.isEmpty || uploading > 0 { attachments }
            TextEditor(text: $draft.text)
                .font(Look.size(15)).lineSpacing(3)
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .body)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { for url in urls { await addFile(url) } } }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { for url in urls { await addFile(url) } }
            return true
        }
    }

    /// The files added so far, each with a button to take it off again.
    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(files) { f in
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                        Text(f.name).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file)).foregroundStyle(.secondary)
                        Button { files.removeAll { $0.id == f.id } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove \(f.name)")
                    }
                    .font(Look.size(12.5))
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Look.ground))
                }
                if uploading > 0 {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Adding…") }
                        .font(Look.size(12.5)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
    }

    private func addFile(_ url: URL) async {
        let open = url.startAccessingSecurityScopedResource()
        defer { if open { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { problem = "Couldn't read \(url.lastPathComponent)."; return }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        await upload(data, name: url.lastPathComponent, type: type)
    }

    #if os(iOS)
    private func addPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { problem = "Couldn't read that photo."; return }
        let kind = item.supportedContentTypes.first ?? .jpeg
        let ext = kind.preferredFilenameExtension ?? "jpg"
        await upload(data, name: "Photo \(files.count + 1).\(ext)", type: kind.preferredMIMEType ?? "image/jpeg")
    }
    #endif

    private func upload(_ data: Data, name: String, type: String) async {
        guard let account = draft.account else { return }
        uploading += 1
        defer { uploading -= 1 }
        do { files.append(try await store.attach(data, name: name, type: type, account: account)) }
        catch { problem = error.localizedDescription }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(label).font(Look.size(14)).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
                content()
            }
            .padding(.horizontal, 20).frame(minHeight: 42)
            Divider().padding(.leading, 20)
        }
    }

    private func send() async {
        guard let account = draft.account, let s = store.state(for: account),
              let identity = s.identities.first(where: { $0.id == draft.identityId }) else { return }
        sending = true; problem = nil
        do {
            let address = identity.isWildcard ? draft.fromEmail.trimmingCharacters(in: .whitespaces) : nil
            try await store.send(account: account, identity: identity, as: address, to: EmailAddress.parse(draft.to),
                                 cc: EmailAddress.parse(draft.cc), bcc: EmailAddress.parse(draft.bcc), subject: draft.subject, text: draft.text,
                                 threading: draft.threading, attachments: files, replacing: draft.draftId, sendAt: sendAt)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
        sending = false
    }
}
