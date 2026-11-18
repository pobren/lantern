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
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var text = ""
    var replyTo: Email?

    /// "-- " and the signature, the standard way, so other mail apps know where it starts.
    static func signed(_ signature: String) -> String {
        signature.isEmpty ? "" : "-- \n" + signature
    }

    @MainActor static func new(store: Store) -> ComposeDraft {
        var s = store.accounts.first
        if case .mailbox(let a, _) = store.folder { s = store.state(id: a) ?? s }
        let identity = s?.identities.first
        let sig = identity.map { signed(store.signature(for: $0)) } ?? ""
        return ComposeDraft(account: s?.account, identityId: identity?.id, text: sig.isEmpty ? "" : "\n\n" + sig)
    }

    @MainActor static func reply(to e: Email, account: Account, all: Bool, quoting text: String, store: Store) -> ComposeDraft {
        let s = store.state(for: account)
        let mine = Set(((s?.identities ?? []).map(\.email) + [account.username]).map { $0.lowercased() })
        let wroteTo = (e.to ?? []) + (e.cc ?? [])
        let identity = s?.identities.first { id in wroteTo.contains { $0.email.lowercased() == id.email.lowercased() } } ?? s?.identities.first
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
        return ComposeDraft(account: account, identityId: identity?.id,
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
        let identity = s?.identities.first
        return ComposeDraft(account: account, identityId: identity?.id,
                            subject: title.lowercased().hasPrefix("fwd:") ? title : "Fwd: \(title)",
                            text: "\n\n" + block(identity, store) + header + "\n\n" + text)
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
    #if os(iOS)
    @State private var photos: [PhotosPickerItem] = []
    #endif

    private enum Field { case to, body }

    init(draft: ComposeDraft) {
        _draft = State(initialValue: draft)
        _showCc = State(initialValue: !draft.cc.isEmpty)
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

    private var canSend: Bool {
        !(EmailAddress.parse(draft.to) + EmailAddress.parse(draft.bcc)).isEmpty && draft.account != nil && draft.identityId != nil && !sending && uploading == 0
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Text(title).font(Look.size(15, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
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
        #endif
    }

    private var title: String {
        if draft.replyTo != nil { return "Reply" }
        if draft.subject.hasPrefix("Fwd:") { return "Forward" }
        return "New message"
    }

    private var sendButton: some View {
        Button { Task { await send() } } label: {
            if sending { ProgressView().controlSize(.small) } else { Label("Send", systemImage: "paperplane") }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canSend)
    }

    private var form: some View {
        VStack(spacing: 0) {
            if choices.count > 1 {
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
            row("To") {
                TextField("", text: $draft.to)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .to)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                if !showCc { Button("Cc") { showCc = true }.buttonStyle(.borderless) }
                if !showBcc { Button("Bcc") { showBcc = true }.buttonStyle(.borderless) }
            }
            if showCc {
                row("Cc") {
                    TextField("", text: $draft.cc)
                        .textFieldStyle(.plain)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
            }
            if showBcc {
                row("Bcc") {
                    TextField("", text: $draft.bcc)
                        .textFieldStyle(.plain)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
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
            try await store.send(account: account, identity: identity, to: EmailAddress.parse(draft.to),
                                 cc: EmailAddress.parse(draft.cc), bcc: EmailAddress.parse(draft.bcc), subject: draft.subject, text: draft.text, replyTo: draft.replyTo,
                                 attachments: files)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
        sending = false
    }
}
