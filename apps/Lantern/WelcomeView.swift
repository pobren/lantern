// First run: add a Fastmail account (Mail App and other JMAP servers later) with an API token. Also Settings, on every device.

import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var store: Store
    @State private var kind: ServerKind?

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            Image("Logo")
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("Welcome to JMAP Connect").font(Look.size(28, weight: .semibold))
                Text(ServerKind.fastmailOnly ? "The native mail app for Fastmail. Fast, simple and private." : "Your Mail App and Fastmail email in one fast, native app.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            }
            if ServerKind.fastmailOnly {
                Button { kind = .fastmail } label: {
                    Label("Add your Fastmail account", systemImage: "plus.circle").frame(maxWidth: .infinity).frame(height: 40)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .frame(maxWidth: 400)
                Button { Task { await store.addDemo() } } label: {
                    Label("Try it with sample mail", systemImage: "tray.full")
                }
                .buttonStyle(.borderless)
            } else {
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
            }
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
    @State private var masking: AccountState?
    @AppStorage("remoteImages") private var remoteImages = true
    @AppStorage(Gravatar.key) private var gravatar = true
    @AppStorage(Notifier.enabledKey) private var notify = true
    @AppStorage(Notifier.badgeKey) private var badge = true
    #if os(iOS)
    @AppStorage(InstantAlerts.enabledKey) private var instant = false
    @ObservedObject private var alerts = InstantAlerts.shared
    #endif

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Tell me about new mail", isOn: $notify)
                    .onChange(of: notify) { _, on in if on { Task { await Notifier.ask() } } }
                Toggle("Show the unread count on the app icon", isOn: $badge)
                    .onChange(of: badge) { _, _ in Notifier.badge(store.unreadInboxes) }
                #if os(iOS)
                Toggle("Instant alerts", isOn: $instant)
                    .disabled(!notify)
                    .onChange(of: instant) { _, _ in Task { await alerts.sync(store) } }
                if instant {
                    if alerts.working { ProgressView().controlSize(.small) }
                    if !alerts.status.isEmpty { Text(alerts.status).font(.caption).foregroundStyle(.secondary) }
                    Text("Fastmail tells our relay the moment mail arrives, and the relay wakes this device. Your email never passes through us: Fastmail encrypts the notice for this device, which then fetches the sender and subject from Fastmail itself.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Without instant alerts, iPhone and iPad check for mail in the background when iOS allows, usually every 15 minutes or so.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                #endif
            }
            Section("Sending") {
                ForEach(store.accounts) { s in
                    if s.identities.count > 1 {
                        Picker(store.accounts.count > 1 ? "Send new emails from (\(s.account.label))" : "Send new emails from",
                               selection: Binding(get: { store.defaultIdentity(s)?.id ?? "" },
                                                  set: { store.setDefaultIdentity($0, account: s.account) })) {
                            ForEach(s.identities) { Text($0.label).tag($0.id) }
                        }
                    }
                }
                Text("Replies go out from the address the email was sent to, when you can send from it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Your addresses") {
                ForEach(store.accounts) { s in
                    ForEach(s.identities) { identity in
                        SignatureRow(identity: identity, account: s.account)
                    }
                }
                Text("Reply to addresses and signatures are saved to your account, so they match on the web and in other apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Reading") {
                Toggle("Load pictures from the web in emails", isOn: $remoteImages)
                Text("Turn this off to stop senders seeing when you open their emails. You can still show pictures on any email.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show senders' Gravatar pictures", isOn: $gravatar)
            }
            OfflineSection()
            Section("Masked Email") {
                ForEach(store.accounts.filter { $0.account.kind == "fastmail" }) { s in
                    Button { masking = s } label: {
                        Label(store.accounts.count > 1 ? "Masked addresses for \(s.account.label)" : "Masked addresses", systemImage: "theatermasks")
                    }
                }
                Text("Make a private address for each website, copy it in one tap, and turn it off if it starts getting spam.")
                    .font(.caption).foregroundStyle(.secondary)
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
                        Button("Remove", role: .destructive) {
                            store.remove(s)
                            #if os(iOS)
                            Task { await InstantAlerts.shared.sync(store) }
                            #endif
                        }
                    }
                }
                if ServerKind.fastmailOnly {
                    Button { adding = .fastmail } label: { Label("Add another Fastmail account", systemImage: "plus") }
                } else {
                    Menu {
                        Button("Mail App") { adding = .mailApp }
                        Button("Fastmail") { adding = .fastmail }
                        Button("Another JMAP server") { adding = .other }
                    } label: { Label("Add account", systemImage: "plus") }
                }
            }
        }
        .sheet(item: $masking) { s in MaskedEmailView(state: s) }
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

/// How much mail is kept on the device for reading and searching offline, the space it takes, and clearing it.
struct OfflineSection: View {
    @EnvironmentObject var store: Store
    @AppStorage(Store.offlineMonthsKey) private var months = Store.offlineMonths
    @State private var size: Int64?
    @State private var clearing = false

    var body: some View {
        Section("Offline") {
            Picker("Keep full emails for", selection: $months) {
                Text("1 month").tag(1)
                Text("3 months").tag(3)
                Text("12 months").tag(12)
                Text("All mail").tag(0)
            }
            .onChange(of: months) { _, _ in store.offlineWindowChanged(); Task { await measure() } }
            HStack {
                Text("Space used on this device")
                Spacer()
                Text(size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Working it out")
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                clearing = true
                Task { await store.clearSaved(); await measure(); clearing = false }
            } label: { Label(clearing ? "Clearing" : "Clear saved mail", systemImage: "trash") }
            .disabled(clearing)
            Text("Every email's sender, subject and preview is kept so lists and search work offline, plus the full text of emails from the time above and any attachments you've opened. Full emails download on Wi-Fi only. Saved mail stays on this device, isn't backed up to iCloud, and downloads again after clearing.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await measure() }
    }

    private func measure() async { size = await store.savedSize() }
}

/// One address's signature, edited in place and saved to the account when you press Save.
struct SignatureRow: View {
    @EnvironmentObject var store: Store
    let identity: Identity
    let account: Account
    @State private var text = ""
    @State private var replyTo = ""
    @State private var saving = false

    private var changed: Bool { text != (identity.textSignature ?? "") || replyTo != identity.replyToText }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(identity.label).font(.callout)
            TextField("Replies go to (leave empty for this address)", text: $replyTo)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            Text("Signature").font(.caption).foregroundStyle(.secondary)
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
                        if replyTo != identity.replyToText { _ = await store.saveReplyTo(replyTo, identity: identity, account: account) }
                        if text != (identity.textSignature ?? "") { await store.saveSignature(text, identity: identity, account: account) }
                        saving = false
                    }
                } label: {
                    if saving { ProgressView().controlSize(.small) } else { Label("Save", systemImage: "checkmark") }
                }
                .disabled(saving || !changed)
            }
        }
        .onAppear { text = identity.textSignature ?? ""; replyTo = identity.replyToText }
    }
}
