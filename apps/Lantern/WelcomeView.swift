// First run: add a Mail App, Fastmail or other JMAP account with an API token. Also Settings, on every device.

import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var store: Store
    @State private var kind: ServerKind?

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            Image(systemName: "envelope.fill")
                .font(Look.size(40, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 88, height: 88)
                .background(RoundedRectangle(cornerRadius: 22).fill(Look.accent))
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("Welcome to JMAP Connect").font(Look.size(28, weight: .semibold))
                Text("Your Mail App and Fastmail email in one fast, native app.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            }
            VStack(spacing: 10) {
                Button { kind = .mailApp } label: {
                    Label("Add a Mail App account", systemImage: "plus.circle").frame(maxWidth: .infinity).frame(height: 40)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button { kind = .fastmail } label: {
                    Label("Add a Fastmail account", systemImage: "envelope").frame(maxWidth: .infinity).frame(height: 40)
                }
                .buttonStyle(.bordered).controlSize(.large)
                Button { kind = .other } label: { Label("Another JMAP server", systemImage: "server.rack") }
                    .buttonStyle(.borderless)
            }
            .frame(maxWidth: 400)
            ViewThatFits {
                HStack(spacing: 26) { promises }
                VStack(spacing: 8) { promises }
            }
            .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text("Not affiliated with Fastmail. Fastmail is a trademark of its owner.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Look.paper)
        .sheet(item: $kind) { k in AddAccountView(kind: k).environmentObject(store) }
    }

    @ViewBuilder private var promises: some View {
        Label("Your mail goes straight to your provider", systemImage: "lock")
        Label("New mail arrives instantly", systemImage: "bolt")
    }
}

struct AddAccountView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let kind: ServerKind
    @State private var address = ""
    @State private var token = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add \(kind.name)").font(Look.size(20, weight: .semibold))
            Text(kind.tokenHelp).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if kind.sessionURL.isEmpty {
                TextField(kind.id == "mailapp" ? "Mail App address, such as mail.yourdomain.com" : "JMAP session address", text: $address)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }
            SecureField("API token", text: $token).textFieldStyle(.roundedBorder)
            if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    Task {
                        working = true; problem = nil
                        do { try await store.add(kind: kind, address: address, token: token); dismiss() }
                        catch { problem = error.localizedDescription }
                        working = false
                    }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Label("Add account", systemImage: "checkmark") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(token.isEmpty || (kind.sessionURL.isEmpty && address.isEmpty) || working)
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 480)
        #else
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium, .large])
        #endif
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var adding: ServerKind?
    @AppStorage("remoteImages") private var remoteImages = true
    @AppStorage(Gravatar.key) private var gravatar = true
    @AppStorage(Notifier.enabledKey) private var notify = true
    @AppStorage(Notifier.badgeKey) private var badge = true

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Tell me about new mail", isOn: $notify)
                    .onChange(of: notify) { _, on in if on { Task { await Notifier.ask() } } }
                Toggle("Show the unread count on the app icon", isOn: $badge)
                    .onChange(of: badge) { _, _ in Notifier.badge(store.unreadInboxes) }
                #if os(iOS)
                Text("iPhone and iPad check for mail in the background when iOS allows, usually every 15 minutes or so.")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
            }
            Section("Signatures") {
                ForEach(store.accounts) { s in
                    ForEach(s.identities) { identity in
                        SignatureRow(identity: identity, account: s.account)
                    }
                }
                Text("Signatures are saved to your account, so they match on the web and in other apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Reading") {
                Toggle("Load pictures from the web in emails", isOn: $remoteImages)
                Text("Turn this off to stop senders seeing when you open their emails. You can still show pictures on any email.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show senders' Gravatar pictures", isOn: $gravatar)
            }
            Section("Accounts") {
                ForEach(store.accounts) { s in
                    HStack {
                        AccountDot(account: s.account, size: 9)
                        VStack(alignment: .leading) {
                            Text(s.account.kindName)
                            Text(s.account.username).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { store.remove(s) }
                    }
                }
                Menu {
                    Button("Mail App") { adding = .mailApp }
                    Button("Fastmail") { adding = .fastmail }
                    Button("Another JMAP server") { adding = .other }
                } label: { Label("Add account", systemImage: "plus") }
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 500, height: 620)
        #else
        .safeAreaInset(edge: .top) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
        }
        #endif
        .sheet(item: $adding) { k in AddAccountView(kind: k).environmentObject(store) }
    }
}

/// One address's signature, edited in place and saved to the account when you press Save.
struct SignatureRow: View {
    @EnvironmentObject var store: Store
    let identity: Identity
    let account: Account
    @State private var text = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(identity.label).font(.callout)
            TextEditor(text: $text)
                .font(Look.size(13))
                .frame(minHeight: 70)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Look.ground))
            HStack {
                Spacer()
                Button {
                    Task {
                        saving = true
                        await store.saveSignature(text, identity: identity, account: account)
                        saving = false
                    }
                } label: {
                    if saving { ProgressView().controlSize(.small) } else { Label("Save", systemImage: "checkmark") }
                }
                .disabled(saving || text == (identity.textSignature ?? ""))
            }
        }
        .onAppear { text = identity.textSignature ?? "" }
    }
}
