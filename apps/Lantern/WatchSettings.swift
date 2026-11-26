// Settings, Apple Watch (iPhone only): the quick replies the Watch and alerts offer, and a Fastmail sign in of the
// Watch's own, so it keeps working when the iPhone isn't nearby.

import Foundation

extension QuickReplies {
    static let key = "quickReplies"

    /// The quick replies as set in Settings, or the starting list.
    static var current: [String] {
        guard let list = UserDefaults.standard.stringArray(forKey: key), !list.isEmpty else { return defaults }
        return list
    }

    static func save(_ list: [String]) {
        let tidy = list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        UserDefaults.standard.set(tidy, forKey: key)
    }
}

#if os(iOS)
import SwiftUI
import AuthenticationServices

/// Accounts whose Watch has its own sign in, with when it was sent (kept on the iPhone only to show the state).
enum WatchSignIns {
    private static let key = "watchSignIns"
    static var all: [String: Double] { UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:] }
    static func set(_ id: String, _ on: Bool) {
        var a = all
        a[id] = on ? Date().timeIntervalSince1970 : nil
        UserDefaults.standard.set(a, forKey: key)
    }
}

struct WatchSettingsPage: View {
    @EnvironmentObject var store: Store
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var replies = QuickReplies.current
    @State private var newReply = ""
    @State private var signedIn = WatchSignIns.all
    @State private var working: String?
    @State private var problem: String?

    private var fastmail: [AccountState] {
        store.accounts.filter { s in Keychain.read(s.account.id).map(FastmailOAuth.isOAuth) ?? false }
    }

    var body: some View {
        Form {
            Section {
                ForEach(replies, id: \.self) { r in Text(r) }
                .onDelete { replies.remove(atOffsets: $0); saveReplies() }
                .onMove { replies.move(fromOffsets: $0, toOffset: $1); saveReplies() }
                HStack {
                    TextField("New quick reply", text: $newReply).onSubmit(addReply)
                    Button(action: addReply) { Label("Add", systemImage: "plus.circle.fill") }
                        .labelStyle(.iconOnly)
                        .disabled(newReply.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if replies != QuickReplies.defaults {
                    Button { replies = QuickReplies.defaults; saveReplies() } label: {
                        Label("Back to the starting list", systemImage: "arrow.uturn.backward")
                    }
                }
            } header: { Text("Quick replies") } footer: {
                Text("Tap one on your Apple Watch under Reply to send it straight away. Swipe left to remove one.")
            }

            if !fastmail.isEmpty {
                Section {
                    ForEach(fastmail) { s in
                        let on = signedIn[s.account.id] != nil
                        HStack {
                            Label(s.account.label, systemImage: on ? "applewatch.radiowaves.left.and.right" : "applewatch")
                            Spacer()
                            if working == s.account.id {
                                ProgressView()
                            } else if on {
                                Button(role: .destructive) { forget(s) } label: { Label("Turn off", systemImage: "xmark.circle") }
                                    .buttonStyle(.borderless)
                            } else {
                                Button { signIn(s) } label: { Label("Sign in", systemImage: "person.badge.key") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                } header: { Text("Away from your iPhone") } footer: {
                    Text("Without this, your Watch uses your iPhone's Fastmail sign in, which lasts about an hour once your iPhone is out of reach. Sign in once more here and the Watch gets a sign in of its own, so it keeps checking mail over Wi-Fi or mobile signal. It goes straight to your Watch; nothing is kept on this iPhone or sent anywhere else.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    private func saveReplies() {
        QuickReplies.save(replies)
        replies = QuickReplies.current
        WatchLink.shared.send()
    }

    private func addReply() {
        let r = newReply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return }
        replies.append(r)
        newReply = ""
        saveReplies()
    }

    /// A second Fastmail sign in, made here and handed to the Watch. It must be the same Fastmail account.
    private func signIn(_ s: AccountState) {
        Task {
            working = s.account.id; problem = nil
            defer { working = nil }
            guard WatchLink.shared.watchReady else {
                problem = "Your Watch isn't connected. Open JMAP Connect on your Watch, then try again."
                return
            }
            let request = FastmailOAuth.start()
            do {
                let back = try await webAuth.authenticate(using: request.url, callbackURLScheme: FastmailOAuth.callbackScheme,
                                                          preferredBrowserSession: .ephemeral)
                let secret = try await FastmailOAuth.finish(back, request: request)
                let key = FastmailOAuth.keyId(secret)
                guard let tokens = OAuthStore.read(key) else { throw FastmailOAuth.Failure.signedOut(nil) }
                let who = await username(tokens.access)
                guard who == nil || who?.lowercased() == s.account.username.lowercased() else {
                    await FastmailOAuth.signOut(secret)
                    problem = "That was \(who ?? "another account"). Sign in as \(s.account.username) for this one."
                    return
                }
                guard WatchLink.shared.sendGrant(account: s.account.id, tokens) else {
                    await FastmailOAuth.signOut(secret)
                    problem = "Your Watch isn't connected. Open JMAP Connect on your Watch, then try again."
                    return
                }
                OAuthStore.delete(key)   // the Watch holds it from now on
                WatchSignIns.set(s.account.id, true)
                signedIn = WatchSignIns.all
            } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            } catch FastmailOAuth.Failure.cancelled {
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func forget(_ s: AccountState) {
        WatchLink.shared.forgetGrant(account: s.account.id)
        WatchSignIns.set(s.account.id, false)
        signedIn = WatchSignIns.all
    }

    /// The account name Fastmail gives for a token, to check the right account signed in.
    private func username(_ access: String) async -> String? {
        var r = URLRequest(url: URL(string: FastmailOAuth.sessionURL)!)
        r.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: r),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["username"] as? String
    }
}
#endif
