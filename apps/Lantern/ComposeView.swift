// Writing a new email or a reply, from any of your addresses on any account.

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
        let s = store.accounts.first
        return ComposeDraft(account: s?.account, identityId: s?.identities.first?.id)
    }

    @MainActor static func reply(to item: Item, store: Store) -> ComposeDraft {
        let s = store.state(for: item.account)
        let mine = Set((s?.identities ?? []).map { $0.email.lowercased() })
        let wroteTo = (item.email.to ?? []) + (item.email.cc ?? [])
        let identity = s?.identities.first { id in wroteTo.contains { $0.email.lowercased() == id.email.lowercased() } } ?? s?.identities.first
        let fromMe = mine.contains(item.email.sender.email.lowercased())
        let to = fromMe ? (item.email.to ?? []) : [item.email.sender]
        let title = item.email.title
        return ComposeDraft(account: item.account, identityId: identity?.id,
                            to: to.map { a in a.name.map { n in "\(n) <\(a.email)>" } ?? a.email }.joined(separator: ", "),
                            subject: title.lowercased().hasPrefix("re:") ? title : "Re: \(title)",
                            replyTo: item.email)
    }
}

struct ComposeView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var draft: ComposeDraft
    @State private var showCc = false
    @State private var sending = false
    @State private var problem: String?

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
        VStack(spacing: 0) {
            HStack {
                Text(draft.replyTo == nil ? "New message" : "Reply").font(Look.display(20))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction).accessibilityLabel("Close")
            }
            .padding(.horizontal, 22).frame(height: 54)
            Divider()
            VStack(spacing: 0) {
                row("From") {
                    Picker("", selection: chosenKey) {
                        ForEach(choices.indices, id: \.self) { i in
                            let (account, identity) = choices[i]
                            Text("\(identity.label) (\(account.label))").tag("\(account.id)|\(identity.id)")
                        }
                    }
                    .labelsHidden()
                }
                row("To") {
                    TextField("Name <address>, separated by commas", text: $draft.to).textFieldStyle(.plain)
                    if !showCc { Button("Cc") { showCc = true }.buttonStyle(.borderless) }
                }
                if showCc { row("Cc") { TextField("", text: $draft.cc).textFieldStyle(.plain) } }
                row("Subject") { TextField("", text: $draft.subject).textFieldStyle(.plain) }
            }
            TextEditor(text: $draft.text)
                .font(.system(size: 14.5)).lineSpacing(4)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .frame(minHeight: 260)
            Divider()
            HStack {
                if let problem { Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Text("⌘↩ to send").font(.caption).foregroundStyle(Look.muted)
                Button { Task { await send() } } label: {
                    if sending { ProgressView().controlSize(.small) } else { Label("Send", systemImage: "paperplane") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
            }
            .padding(.horizontal, 22).frame(height: 56)
        }
        .frame(width: 680, height: 560)
        .background(Color.white)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(label).font(.system(size: 13)).foregroundStyle(Look.muted).frame(width: 60, alignment: .leading)
                content()
            }
            .padding(.horizontal, 22).frame(height: 42)
            Divider().padding(.leading, 22)
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
