// Writing a new email, a reply, a reply to all or a forward, from any of your addresses on any account.

import SwiftUI

struct ComposeDraft: Identifiable {
    let id = UUID()
    var account: Account?
    var identityId: String?
    var to = ""
    var cc = ""
    var subject = ""
    var text = ""
    var replyTo: Email?

    @MainActor static func new(store: Store) -> ComposeDraft {
        var s = store.accounts.first
        if case .mailbox(let a, _) = store.folder { s = store.state(id: a) ?? s }
        return ComposeDraft(account: s?.account, identityId: s?.identities.first?.id)
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
                            text: "\n\n" + quote(e, text),
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
        return ComposeDraft(account: account, identityId: s?.identities.first?.id,
                            subject: title.lowercased().hasPrefix("fwd:") ? title : "Fwd: \(title)",
                            text: "\n\n" + header + "\n\n" + text)
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
    @State private var sending = false
    @State private var problem: String?
    @FocusState private var focus: Field?

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
                draft.account = store.accounts.first { $0.id == parts[0] }?.account
                draft.identityId = parts[1]
            })
    }

    private var canSend: Bool {
        !EmailAddress.parse(draft.to).isEmpty && draft.account != nil && draft.identityId != nil && !sending
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold))
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
            row("Subject") { TextField("", text: $draft.subject).textFieldStyle(.plain) }
            TextEditor(text: $draft.text)
                .font(.system(size: 15)).lineSpacing(3)
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .body)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(label).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
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
                                 cc: EmailAddress.parse(draft.cc), subject: draft.subject, text: draft.text, replyTo: draft.replyTo)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
        sending = false
    }
}
