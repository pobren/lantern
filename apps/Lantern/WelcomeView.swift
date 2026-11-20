// First run: add a Fastmail account with an API token, or (smaller, underneath) another JMAP provider with an email
// address and app password. Also Settings, on every device.

import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var store: Store
    @State private var kind: ServerKind?
    @State private var other = false

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
                Text("The native mail app for Fastmail. Fast, simple and private.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            }
            VStack(spacing: 12) {
                Button { kind = .fastmail } label: {
                    Label("Add your Fastmail account", systemImage: "plus.circle").frame(maxWidth: .infinity).frame(height: 40)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                if ServerKind.otherProviders {
                    Button { other = true } label: {
                        Label("Use Mail App or another JMAP provider", systemImage: "server.rack")
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
                Button { Task { await store.addDemo() } } label: {
                    Label("Try it with sample mail", systemImage: "tray.full")
                }
                .buttonStyle(.borderless)
                .font(.callout)
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
        .sheet(isPresented: $other) { OtherAccountView().environmentObject(store) }
        .task {
            if Demo.launchedForScreens && Demo.screen == "other" {
                try? await Task.sleep(nanoseconds: 800_000_000)
                other = true
            }
        }
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
            let saved = store.savedKeys(kind: kind)
            if !saved.isEmpty {
                // Keys this person used before, kept in their iCloud Keychain: no new key needed.
                ForEach(saved) { k in
                    Button {
                        Task {
                            working = true; problem = nil
                            do { try await store.add(saved: k); dismiss() }
                            catch { problem = signInProblem(error) }
                            working = false
                        }
                    } label: {
                        Label("Sign back in as \(k.username)", systemImage: "key.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(working)
                }
                Text("Or use a new key:").font(.callout).foregroundStyle(.secondary)
            }
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
            if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    Task {
                        working = true; problem = nil
                        do { try await store.add(kind: kind, address: address, token: token); dismiss() }
                        catch { problem = signInProblem(error) }
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

/// Stalwart, Thundermail, Mailbux, Cyrus or any other JMAP server: pick the provider, then email address and
/// app password. The server's address is only asked for where it can't be known (self hosted servers), and even
/// then it can be left empty to find it from the email address.
struct OtherAccountView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var provider = ServerKind.providers[0]
    @State private var email = ""
    @State private var password = ""
    @State private var server = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Mail App or another JMAP provider").font(Look.size(20, weight: .semibold))
            let saved = store.savedKeys(kinds: ServerKind.providers)
            if !saved.isEmpty {
                ForEach(saved) { k in
                    Button {
                        Task {
                            working = true; problem = nil
                            do { try await store.add(saved: k); dismiss() }
                            catch { problem = signInProblem(error) }
                            working = false
                        }
                    } label: {
                        Label("Sign back in as \(k.username)", systemImage: "key.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(working)
                }
                Text("Or add a new account:").font(.callout).foregroundStyle(.secondary)
            }
            Picker("Provider", selection: $provider) {
                ForEach(ServerKind.providers) { Text($0.name).tag($0) }
            }
            .onChange(of: provider) { _, _ in problem = nil }
            Text(provider.tokenHelp).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Email address", text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)
                #if os(iOS)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            SecureField(provider.id == ServerKind.mailApp.id ? "API key" : "App password", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
            if provider.asksServer {
                TextField(provider.id == ServerKind.mailApp.id ? "Mail App address, such as mail.example.com" : "Server, such as mail.example.com (optional)", text: $server)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button { dismiss() } label: { Label("Cancel", systemImage: "xmark") }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    Task {
                        working = true; problem = nil
                        do {
                            try await store.add(kind: provider, email: email, password: password, server: provider.asksServer ? server : "")
                            dismiss()
                        } catch { problem = signInProblem(error) }
                        working = false
                    }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Label("Add account", systemImage: "checkmark") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || (email.isEmpty && server.isEmpty) || (provider.id == ServerKind.mailApp.id && server.isEmpty) || working)
            }
            Text("Your mail goes straight between this device and your provider. Not affiliated with any provider.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
    @State private var addingOther = false
    @State private var masking: AccountState?
    @State private var away: AccountState?
    @State private var removing: AccountState?

    private func remove(forgetKey: Bool) {
        guard let s = removing else { return }
        removing = nil
        store.remove(s, forgetKey: forgetKey)
        #if os(iOS)
        Task { await InstantAlerts.shared.sync(store) }
        #endif
    }
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
        .sheet(item: $away) { s in OutOfOfficeView(state: s) }
        .sheet(item: $adding) { k in AddAccountView(kind: k).environmentObject(store) }
        .sheet(isPresented: $addingOther) { OtherAccountView().environmentObject(store) }
        #else
        TabView {
            Form { notifications; reading }.formStyle(.grouped)
                .tabItem { Label("General", systemImage: "gearshape") }
            Form { sending; addresses }.formStyle(.grouped)
                .tabItem { Label("Sending", systemImage: "paperplane") }
            Form { OfflineSection() }.formStyle(.grouped)
                .tabItem { Label("Offline", systemImage: "arrow.down.circle") }
            Form { fastmailTools }.formStyle(.grouped)
                .tabItem { Label(onlyFastmail ? "Fastmail" : "Extras", systemImage: "envelope.badge.shield.half.filled") }
            Form { Section("Accounts") { accounts }; Section { about } }.formStyle(.grouped)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
        }
        .frame(width: 560, height: 520)
        .sheet(item: $masking) { s in MaskedEmailView(state: s) }
        .sheet(item: $away) { s in OutOfOfficeView(state: s) }
        .sheet(item: $adding) { k in AddAccountView(kind: k).environmentObject(store) }
        .sheet(isPresented: $addingOther) { OtherAccountView().environmentObject(store) }
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
                 ? "Your mail server tells our relay the moment mail arrives, and the relay wakes this device. Your email never passes through us: the server encrypts the notice for this device, which then fetches the sender and subject from the server itself."
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
                        ForEach(s.identities) { Text($0.email).tag($0.id) }
                    }
                    #if os(iOS)
                    .pickerStyle(.navigationLink)
                    #endif
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
            Text(onlyFastmail ? "Saved to your Fastmail account, so they match on the web and in other apps." : "Saved to your mail account, so they match on the web and in other apps.")
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
        let canAway = store.accounts.filter { $0.client.canVacation }
        if !fastmail.isEmpty || !canAway.isEmpty {
            Section {
                // Separate ids for the two lists: with the same account id twice, the Mac drew Masked Email twice.
                ForEach(fastmail, id: \.maskKey) { s in
                    Button { masking = s } label: {
                        Row(title: store.accounts.count > 1 ? "Masked Email, \(s.account.label)" : "Masked Email", icon: "theatermasks.fill", tint: .indigo)
                    }
                }
                ForEach(canAway, id: \.awayKey) { s in
                    Button { away = s } label: {
                        Row(title: store.accounts.count > 1 ? "Out of office, \(s.account.label)" : "Out of office", icon: "airplane.departure", tint: .orange)
                    }
                }
            } header: { Text(onlyFastmail ? "Fastmail" : "Extras") } footer: {
                if fastmail.isEmpty {
                    Text("Out of office replies are saved on your mail server, so they work with every device switched off.")
                } else {
                    Text("Masked Email makes a private address for each website. Out of office replies are saved \(onlyFastmail ? "in Fastmail" : "on your mail server"), so they work with every device switched off.")
                }
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
                Button(role: .destructive) { removing = s } label: { Label("Remove", systemImage: "minus.circle") }
                .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.red)
                .accessibilityLabel("Remove \(s.account.label)")
            }
        }
        Color.clear.frame(height: 0)
            .confirmationDialog("Remove \(removing?.account.label ?? "this account")?",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible) {
                Button(role: .destructive) { remove(forgetKey: false) } label: { Label("Remove, keep the key", systemImage: "minus.circle") }
                Button(role: .destructive) { remove(forgetKey: true) } label: { Label("Remove and forget the key", systemImage: "key.slash") }
                Button("Cancel", role: .cancel) { removing = nil }
            } message: {
                Text("Your mail stays \(onlyFastmail ? "in Fastmail" : "with your provider"). Keep the key and you can sign back in with one tap, here or on your other devices. Forget it and you'll need a new key next time.")
            }
        Button { adding = .fastmail } label: { Label("Add a Fastmail account", systemImage: "plus.circle.fill") }
        if ServerKind.otherProviders {
            Button { addingOther = true } label: { Label("Add Mail App or another JMAP provider", systemImage: "server.rack") }
        }
    }

    /// Every real account is Fastmail (or there are none yet), so Fastmail wording fits.
    private var onlyFastmail: Bool {
        store.accounts.allSatisfy { $0.account.kind == ServerKind.fastmail.id || $0.account.kind == Demo.kind }
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
                    Text(store.accounts.count > 1 ? "\(item.identity.email), \(item.account.label)" : item.identity.email).tag(item.key)
                }
            }
            #if os(iOS)
            .pickerStyle(.navigationLink)
            #endif
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

    // Rows of the settings list, like iOS Settings: Reply to on one line, the signature in its own box-free row,
    // and Save underneath. (Paul: the old page had pickers wrapping under their labels and a box in a box.)
    var body: some View {
        Group {
            LabeledContent("Reply to") {
                TextField("Same address", text: $replyTo)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Signature").font(.subheadline).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(Look.size(15))
                    .frame(minHeight: 110)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, -5)
            }
            .padding(.vertical, 4)
            Button {
                Task {
                    saving = true
                    if replyTo != identity.replyToText { _ = await store.saveReplyTo(replyTo, identity: identity, account: account) }
                    if text != (identity.textSignature ?? "") { await store.saveSignature(text, identity: identity, account: account) }
                    saving = false
                }
            } label: {
                HStack {
                    Spacer()
                    if saving { ProgressView().controlSize(.small) } else { Label("Save", systemImage: "checkmark") }
                    Spacer()
                }
            }
            .disabled(saving || !changed)
        }
        .onAppear { text = identity.textSignature ?? ""; replyTo = identity.replyToText }
    }
}

private extension AccountState {
    var maskKey: String { "mask-" + id }
    var awayKey: String { "away-" + id }
}


/// Plain words for the sign-in errors people actually hit, so the sheet doesn't show the system's long TLS text.
func signInProblem(_ error: Error) -> String {
    if let u = error as? URLError {
        switch u.code {
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return "The server's security certificate isn't valid, so JMAP Connect won't connect. Check the server address, or ask whoever runs the server to fix its certificate."
        case .cannotFindHost, .dnsLookupFailed:
            return "Couldn't find that server. Check the address."
        case .notConnectedToInternet, .networkConnectionLost:
            return "You're offline. Check your connection and try again."
        case .timedOut, .cannotConnectToHost:
            return "The server didn't answer. Check the address, or try again in a moment."
        default: break
        }
    }
    return error.localizedDescription
}
