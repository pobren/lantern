// Fastmail Masked Email: make a new private address for a website or a person, copy it, and turn old ones off.
// Uses Fastmail's own JMAP extension (https://www.fastmail.com/dev/). The API token needs Masked Email access.

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct MaskedAddress: Codable, Identifiable, Hashable {
    let id: String
    let email: String
    var state: String            // pending, enabled, disabled or deleted
    var forDomain: String?
    var description: String?
    var lastMessageAt: String?
    var createdAt: String?

    var title: String {
        if let d = description, !d.isEmpty { return d }
        if let f = forDomain, !f.isEmpty { return f.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "") }
        return email
    }
}

extension JMAPClient {
    static let masked = "https://www.fastmail.com/dev/maskedemail"

    private var maskedAccount: String? { session?.primaryAccounts[Self.masked] ?? accountId }

    func maskedAddresses() async throws -> [MaskedAddress] {
        if session == nil { try await connect() }
        guard let acc = maskedAccount else { throw JMAPError.missing("Masked Email") }
        let r = try await call([["MaskedEmail/get", ["accountId": acc, "ids": NSNull()], "m"]], using: [Self.core, Self.masked])
        return try Self.decode([MaskedAddress].self, from: r["m"]?["list"]).filter { $0.state != "deleted" }
    }

    func newMaskedAddress(description: String, website: String) async throws -> MaskedAddress {
        if session == nil { try await connect() }
        guard let acc = maskedAccount else { throw JMAPError.missing("Masked Email") }
        var create: [String: Any] = ["state": "enabled", "description": description]
        let site = website.trimmingCharacters(in: .whitespacesAndNewlines)
        if !site.isEmpty { create["forDomain"] = site.contains("://") ? site : "https://" + site }
        let r = try await call([["MaskedEmail/set", ["accountId": acc, "create": ["n": create]], "s"]], using: [Self.core, Self.masked])
        guard let made = (r["s"]?["created"] as? [String: Any])?["n"] as? [String: Any],
              let id = made["id"] as? String, let email = made["email"] as? String else {
            let why = ((r["s"]?["notCreated"] as? [String: Any])?["n"] as? [String: Any])?["description"] as? String
            throw JMAPError.method("notCreated", why ?? "Fastmail didn't make the address")
        }
        return MaskedAddress(id: id, email: email, state: "enabled", forDomain: create["forDomain"] as? String,
                             description: description, lastMessageAt: nil, createdAt: nil)
    }

    func setMaskedState(_ id: String, _ state: String) async throws {
        if session == nil { try await connect() }
        guard let acc = maskedAccount else { throw JMAPError.missing("Masked Email") }
        _ = try await call([["MaskedEmail/set", ["accountId": acc, "update": [id: ["state": state]]], "s"]], using: [Self.core, Self.masked])
    }
}

/// The list of masked addresses for one account, with a button to make a new one.
struct MaskedEmailView: View {
    let state: AccountState
    @Environment(\.dismiss) private var dismiss
    @State private var list: [MaskedAddress] = []
    @State private var loading = true
    @State private var problem: String?
    @State private var making = false
    @State private var filter = ""
    @State private var copied: String?

    private var shown: [MaskedAddress] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let all = f.isEmpty ? list : list.filter { "\($0.title) \($0.email) \($0.forDomain ?? "")".lowercased().contains(f) }
        return all.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

    var body: some View {
        NavigationStack {
            List {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
                if let copied {
                    Label("Copied \(copied)", systemImage: "doc.on.doc").foregroundStyle(.secondary)
                }
                Section {
                    ForEach(shown.filter { $0.state != "disabled" }) { row($0) }
                } header: { Text("On") }
                let off = shown.filter { $0.state == "disabled" }
                if !off.isEmpty {
                    Section {
                        ForEach(off) { row($0) }
                    } header: { Text("Off: mail to these goes to the bin") }
                }
            }
            .overlay { if loading { ProgressView() } }
            .searchable(text: $filter, prompt: "Search masked addresses")
            .navigationTitle("Masked Email")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { making = true } label: { Label("New masked address", systemImage: "plus") }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label("Done", systemImage: "checkmark") }
                }
            }
            .sheet(isPresented: $making) {
                NewMaskedView(state: state) { made in
                    list.insert(made, at: 0)
                    copy(made.email)
                }
            }
        }
        .task { await load() }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
    }

    private func row(_ m: MaskedAddress) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.title).lineLimit(1)
                Text(m.email).font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            }
            Spacer()
            Button { copy(m.email) } label: { Label("Copy", systemImage: "doc.on.doc") }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
        }
        .contextMenu { actions(m) }
        .swipeActions { actions(m) }
    }

    @ViewBuilder private func actions(_ m: MaskedAddress) -> some View {
        Button { copy(m.email) } label: { Label("Copy address", systemImage: "doc.on.doc") }
        if m.state == "disabled" {
            Button { Task { await change(m, "enabled") } } label: { Label("Turn on", systemImage: "checkmark.circle") }
        } else {
            Button { Task { await change(m, "disabled") } } label: { Label("Turn off", systemImage: "nosign") }
        }
        Button(role: .destructive) { Task { await change(m, "deleted") } } label: { Label("Delete", systemImage: "trash") }
    }

    private func load() async {
        loading = true
        do { list = try await state.client.maskedAddresses(); problem = nil } catch { problem = Self.explain(error) }
        loading = false
    }

    private func change(_ m: MaskedAddress, _ to: String) async {
        do {
            try await state.client.setMaskedState(m.id, to)
            if to == "deleted" { list.removeAll { $0.id == m.id } }
            else if let i = list.firstIndex(where: { $0.id == m.id }) { list[i].state = to }
        } catch { problem = Self.explain(error) }
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        copied = text
    }

    static func explain(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("capability") || text.localizedCaseInsensitiveContains("forbidden")
            || text.localizedCaseInsensitiveContains("Masked Email") {
            return "Your Fastmail API token doesn't allow Masked Email. In Fastmail, make a new token with Masked Email ticked as well, then remove this account and add it again with the new token."
        }
        return text
    }
}

/// Makes a new masked address: a note to remember it by, and the website it's for.
struct NewMaskedView: View {
    let state: AccountState
    let made: (MaskedAddress) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var website = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("What it's for, such as Netflix", text: $note)
                TextField("Website (optional)", text: $website)
                    #if os(iOS)
                    .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                Text("Fastmail makes a new random address that delivers to your inbox. You can turn it off any time.")
                    .font(.caption).foregroundStyle(.secondary)
                if let problem { Text(problem).foregroundStyle(.red).font(.callout) }
            }
            .formStyle(.grouped)
            .navigationTitle("New masked address")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        working = true
                        Task {
                            do {
                                made(try await state.client.newMaskedAddress(description: note, website: website))
                                dismiss()
                            } catch { problem = MaskedEmailView.explain(error) }
                            working = false
                        }
                    } label: { Label(working ? "Making" : "Make and copy", systemImage: "wand.and.stars") }
                    .disabled(working || note.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: { Label("Cancel", systemImage: "xmark") }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 280)
        #endif
    }
}
