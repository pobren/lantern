// First run: add a Fastmail, Mail App or other JMAP account with an API token.

import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var store: Store
    @State private var kind: ServerKind?

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96).accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("Welcome to Lantern").font(Look.display(30))
                Text("One calm inbox for your Fastmail and Mail App accounts. Fast, native and private, built on JMAP.")
                    .font(.title3).foregroundStyle(Look.muted).multilineTextAlignment(.center).frame(maxWidth: 480)
            }
            VStack(spacing: 10) {
                Button { kind = .fastmail } label: {
                    Label("Sign in with Fastmail", systemImage: "envelope").frame(maxWidth: .infinity).frame(height: 40)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button { kind = .mailApp } label: {
                    Label("Add a Mail App account", systemImage: "plus.circle").frame(maxWidth: .infinity).frame(height: 40)
                }
                .buttonStyle(.bordered).controlSize(.large)
                Button { kind = .other } label: { Label("Another JMAP server", systemImage: "server.rack") }
                    .buttonStyle(.link)
            }
            .frame(width: 400)
            HStack(spacing: 26) {
                Label("Your mail goes straight to your provider", systemImage: "lock")
                Label("New mail arrives instantly", systemImage: "bolt")
            }
            .font(.callout).foregroundStyle(Look.muted)
            Spacer()
            Text("Not affiliated with Fastmail. Fastmail is a trademark of its owner.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .sheet(item: $kind) { k in AddAccountView(kind: k).environmentObject(store) }
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
            Text("Add \(kind.name)").font(Look.display(22))
            Text(kind.tokenHelp).foregroundStyle(Look.muted).fixedSize(horizontal: false, vertical: true)
            if kind.sessionURL.isEmpty {
                TextField(kind.id == "mailapp" ? "Mail App address, such as mail.yourdomain.com" : "JMAP session address", text: $address)
                    .textFieldStyle(.roundedBorder)
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
        .frame(width: 480)
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var adding: ServerKind?

    var body: some View {
        Form {
            Section("Accounts") {
                ForEach(store.accounts) { s in
                    HStack {
                        AccountDot(account: s.account, size: 9)
                        VStack(alignment: .leading) {
                            Text(s.account.label)
                            Text(s.account.username).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { store.remove(s) }
                    }
                }
                Menu {
                    Button("Fastmail") { adding = .fastmail }
                    Button("Mail App") { adding = .mailApp }
                    Button("Another JMAP server") { adding = .other }
                } label: { Label("Add account", systemImage: "plus") }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 320)
        .sheet(item: $adding) { k in AddAccountView(kind: k).environmentObject(store) }
    }
}
