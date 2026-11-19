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
        #if os(iOS)
        NavigationStack {
            List {
                Section {
                    NavigationLink { page("Notifications") { notifications } } label: { Row(title: "Notifications", icon: "bell.badge.fill", tint: .red, detail: alertsDetail) }
                    NavigationLink { page("Sending and signatures") { sending; addresses } } label: { Row(title: "Sending and signatures", icon: "paperplane.fill", tint: Look.accent) }
                    NavigationLink { page("Reading") { reading } } label: { Row(title: "Reading", icon: "eye.fill", tint: .teal) }
                    NavigationLink { page("Offline") { OfflineSection() } } label: { Row(title: "Offline", icon: "arrow.down.circle.fill", tint: .green) }
                }
                fastmailTools
                Section("Accounts") { accounts }
                Section { about }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Label("Done", systemImage: "checkmark") }
                }
            }
        }
        .sheet(item: $masking) { s in MaskedEmailView(state: s) }
        .sheet(item: $adding) { k in AddAccountView(kind: k).environmentObject(store) }
        #else
        TabView {
            Form { notifications; reading }.formStyle(.grouped)
                .tabItem { Label("General", systemImage: "gearshape") }
            Form { sending; addresses }.formStyle(.grouped)
                .tabItem { Label("Sending", systemImage: "paperplane") }
            Form { OfflineSection() }.formStyle(.grouped)
                .tabItem { Label("Offline", systemImage: "arrow.down.circle") }
            Form { fastmailTools }.formStyle(.grouped)
                .tabItem { Label("Fastmail", systemImage: "envelope.badge.shield.half.filled") }
            Form { Section("Accounts") { accounts }; Section { about } }.formStyle(.grouped)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
        }
        .frame(width: 560, height: 520)
        .sheet(item: $masking) { s in MaskedEmailView(state: s) }
        .sheet(item: $adding) { k in AddAccountView(kind: k).environmentObject(store) }
        #endif
    }

    // MARK: Pages

    #if os(iOS)
    private func page<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }

    private var alertsDetail: String {
        if !notify { return "Off" }
        return instant ? "Instant" : "On"
    }
    #endif

    /// A settings row with a coloured icon, the way iOS Settings looks.
    private struct Row: View {
        let title: String
        let icon: String
        let tint: Color
        var detail: String? = nil
        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 29, height: 29)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint))
                Text(title).foregroundStyle(.primary)
                Spacer()
                if let detail { Text(detail).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private var notifications: some View {
        Section {
            Toggle("Tell me about new mail", isOn: $notify)
                .onChange(of: notify) { _, on in if on { Task { await Notifier.ask() } } }
            Toggle("Unread count on the app icon", isOn: $badge)
                .onChange(of: badge) { _, _ in Notifier.badge(store.unreadInboxes) }
        } header: { Text("New mail") }
        #if os(iOS)
        Section {
            Toggle("Instant alerts", isOn: $instant)
                .disabled(!notify)
                .onChange(of: instant) { _, _ in Task { await alerts.sync(store) } }
            if instant {
                if alerts.working { ProgressView().controlSize(.small) }
                if !alerts.status.isEmpty { Text(alerts.status).font(.footnote).foregroundStyle(.secondary) }
            }
        } header: { Text("Instant alerts") } footer: {
            Text(instant
                 ? "Fastmail tells our relay the moment mail arrives, and the relay wakes this device. Your email never passes through us: Fastmail encrypts the notice for this device, which then fetches the sender and subject from Fastmail itself."
                 : "Without instant alerts, iPhone and iPad check for mail in the background when iOS allows, usually every 15 minutes or so.")
        }
        #endif
    }

    @ViewBuilder private var sending: some View {
        let several = store.accounts.filter { $0.identities.count > 1 }
        if !several.isEmpty {
            Section {
                ForEach(several) { s in
                    Picker(store.accounts.count > 1 ? "New emails from (\(s.account.label))" : "New emails from",
                           selection: Binding(get: { store.defaultIdentity(s)?.id ?? "" },
                                              set: { store.setDefaultIdentity($0, account: s.account) })) {
                        ForEach(s.identities) { Text($0.label).tag($0.id) }
                    }
                }
            } header: { Text("Sending") } footer: {
                Text("Replies go out from the address the email was sent to, when you can send from it.")
            }
        }
    }

    @ViewBuilder private var addresses: some View {
        Section {
            AddressSettings()
        } header: { Text("Signature and Reply to") } footer: {
            Text("Saved to your Fastmail account, so they match on the web and in other apps.")
        }
    }

    @ViewBuilder private var reading: some View {
        Section {
            Toggle("Load pictures from the web", isOn: $remoteImages)
        } footer: {
            Text("Turn this off to stop senders seeing when you open their emails. You can still show pictures on any email.")
        }
        Section {
            Toggle("Show senders' Gravatar pictures", isOn: $gravatar)
        }
    }

    @ViewBuilder private var fastmailTools: some View {
        let fastmail = store.accounts.filter { $0.account.kind == "fastmail" }
        if !fastmail.isEmpty {
            Section {
                ForEach(fastmail) { s in
                    Button { masking = s } label: {
                        Row(title: store.accounts.count > 1 ? "Masked Email, \(s.account.label)" : "Masked Email", icon: "theatermasks.fill", tint: .indigo)
                    }
                }
            } header: { Text("Fastmail") } footer: {
                Text("Masked Email makes a private address for each website.")
            }
        }
    }

    @ViewBuilder private var accounts: some View {
        ForEach(store.accounts) { s in
            HStack(spacing: 12) {
                AccountDot(account: s.account, size: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.account.username.isEmpty ? s.account.kindName : s.account.username).lineLimit(1)
                    Text(s.account.kindName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    store.remove(s)
                    #if os(iOS)
                    Task { await InstantAlerts.shared.sync(store) }
                    #endif
                } label: { Label("Remove", systemImage: "minus.circle") }
                .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.red)
                .accessibilityLabel("Remove \(s.account.label)")
            }
        }
        if ServerKind.fastmailOnly {
            Button { adding = .fastmail } label: { Label("Add a Fastmail account", systemImage: "plus.circle.fill") }
        } else {
            Menu {
                Button("Mail App") { adding = .mailApp }
                Button("Fastmail") { adding = .fastmail }
                Button("Another JMAP server") { adding = .other }
            } label: { Label("Add account", systemImage: "plus.circle.fill") }
        }
    }

    private var about: some View {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
        return HStack {
            Text("JMAP Connect")
            Spacer()
            Text("Version \(version)").foregroundStyle(.secondary)
        }
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
/// One dropdown of every sending address, then the chosen one's Reply to address and signature.
struct AddressSettings: View {
    @EnvironmentObject var store: Store
    @State private var chosen = ""

    private var all: [(key: String, account: Account, identity: Identity)] {
        store.accounts.flatMap { s in s.identities.map { ("\(s.account.id)|\($0.id)", s.account, $0) } }
    }

    var body: some View {
        let list = all
        if list.isEmpty {
            Text("Your sending addresses show here once your account has loaded.").font(.caption).foregroundStyle(.secondary)
        } else {
            let key = list.contains { $0.key == chosen } ? chosen : list[0].key
            Picker("Address", selection: Binding(get: { key }, set: { chosen = $0 })) {
                ForEach(list, id: \.key) { item in
                    Text(store.accounts.count > 1 ? "\(item.identity.label), \(item.account.label)" : item.identity.label).tag(item.key)
                }
            }
            if let item = list.first(where: { $0.key == key }) {
                SignatureRow(identity: item.identity, account: item.account).id(key)
            }
        }
    }
}

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
