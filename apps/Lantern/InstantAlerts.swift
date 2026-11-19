// Instant alerts on iPhone and iPad (off until you turn it on in Settings).
//
// iOS only lets an app check for mail now and then. For instant alerts we ask Fastmail to post a notice to our
// relay (push.jmapconnect.app) the moment mail arrives (JMAP push), and the relay wakes this device through Apple.
// Fastmail encrypts each notice for a key that never leaves this device, so the relay can't read it, and the relay
// never sees your Fastmail token: the notification extension fetches the sender and subject from Fastmail itself.

#if os(iOS)
import Foundation
import UIKit
import CryptoKit
import UserNotifications

@MainActor
final class InstantAlerts: ObservableObject {
    static let shared = InstantAlerts()
    static let enabledKey = "instantAlerts"
    static let relay = URL(string: "https://push.jmapconnect.app")!
    #if DEBUG
    static let sandbox = true
    #else
    static let sandbox = false
    #endif

    enum Failure: LocalizedError {
        case relay(Int), paused, noAppleAddress, refused(String), noCode
        var errorDescription: String? {
            switch self {
            case .relay(let code): "The alerts relay didn't answer (\(code)). Try again later."
            case .paused: "Instant alerts are paused for now. New mail is still checked in the background."
            case .noAppleAddress: "Apple didn't give this device a push address. Check notifications are on for JMAP Connect in the Settings app."
            case .refused(let why): "Fastmail turned down the request: \(why)"
            case .noCode: "Fastmail didn't confirm in time. Try turning instant alerts off and on again."
            }
        }
    }

    @Published var status = ""
    @Published var working = false
    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    private var deviceToken: String?
    private var waiting: [CheckedContinuation<String?, Never>] = []
    private var running = false

    // MARK: Apple's push address for this device

    func gotDeviceToken(_ data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        finishWaiting(token)
    }

    func deviceTokenFailed() { finishWaiting(nil) }

    private func finishWaiting(_ token: String?) {
        let list = waiting
        waiting = []
        list.forEach { $0.resume(returning: token) }
    }

    private func appleAddress() async -> String? {
        if let deviceToken { return deviceToken }
        return await withCheckedContinuation { c in
            waiting.append(c)
            UIApplication.shared.registerForRemoteNotifications()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                self.finishWaiting(self.deviceToken)
            }
        }
    }

    // MARK: Keeping every account's subscription right

    /// Run on launch, when the app comes back, in background checks and when the switch changes.
    func sync(_ store: Store) async {
        guard !running else { return }
        running = true
        working = true
        defer { running = false; working = false }

        let accounts = store.accounts.filter { $0.account.kind != Demo.kind }
        if !enabled {
            for r in PushRecords.all() { await turnOff(r) }
            status = ""
            return
        }
        for r in PushRecords.all() where !accounts.contains(where: { $0.id == r.accountId }) { await turnOff(r) }
        guard let device = await appleAddress() else {
            status = Failure.noAppleAddress.localizedDescription
            return
        }
        var problems: [String] = []
        for s in accounts {
            do { try await keep(s, device: device) } catch {
                problems.append(accounts.count > 1 ? "\(s.account.label): \(error.localizedDescription)" : error.localizedDescription)
            }
        }
        // The extension sets the icon's unread count with each alert, if that's switched on in Settings.
        let badge = UserDefaults.standard.object(forKey: Notifier.badgeKey) as? Bool ?? true
        for var r in PushRecords.all() where r.badge != badge {
            r.badge = badge
            PushRecords.save(r)
        }
        status = problems.isEmpty ? "On. New mail shows the moment it arrives." : problems.joined(separator: "\n")
    }

    private func keep(_ s: AccountState, device: String) async throws {
        if var r = PushRecords.read(s.id), r.live {
            if r.device != device {
                _ = try await relay("v1/device", r, body: ["device": device, "sandbox": Self.sandbox])
                r.device = device
                PushRecords.save(r)
            }
            if r.expires.timeIntervalSinceNow > 20 * 86_400 { return }
            // Fastmail keeps a subscription for up to 30 days, so stretch it again well before then.
            let want = Date().addingTimeInterval(30 * 86_400)
            let res = try await s.client.call([["PushSubscription/set", ["update": [r.subscriptionId: ["expires": Self.iso(want)]]], "u"]],
                                              using: [JMAPClient.core])
            if let updated = res["u"]?["updated"] as? [String: Any], updated.keys.contains(r.subscriptionId) {
                let set = (updated[r.subscriptionId] as? [String: Any])?["expires"] as? String
                r.expires = set.flatMap(Self.date) ?? want
                PushRecords.save(r)
                return
            }
            // Fastmail no longer has it (it can drop one if the relay paused): start again.
        }
        if let old = PushRecords.read(s.id) { await turnOff(old) }
        try await create(s, device: device)
    }

    private func create(_ s: AccountState, device: String) async throws {
        let session = try await s.client.connect()
        guard let mailAccount = session.primaryAccounts[JMAPClient.mail], let token = Keychain.read(s.id) else { throw Failure.noCode }

        // 1. An address on the relay for Fastmail to post to.
        let reg = try await register(device)
        guard let relayId = reg["id"] as? String, let secret = reg["secret"] as? String, let url = reg["url"] as? String else { throw Failure.relay(0) }

        // 2. A key only this device holds, so Fastmail encrypts every notice for us.
        let key = P256.KeyAgreement.PrivateKey()
        var auth = Data(count: 16)
        _ = auth.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let want = Date().addingTimeInterval(30 * 86_400)
        let res = try await s.client.call([["PushSubscription/set", ["create": ["p": [
            "deviceClientId": "jmap-connect-\(Self.installId)-\(s.id)",
            "url": url,
            "types": ["EmailDelivery"],
            "keys": ["p256dh": key.publicKey.x963Representation.base64URL, "auth": auth.base64URL],
            "expires": Self.iso(want),
        ]]], "c"]], using: [JMAPClient.core])
        guard let made = (res["c"]?["created"] as? [String: Any])?["p"] as? [String: Any], let subId = made["id"] as? String else {
            let why = ((res["c"]?["notCreated"] as? [String: Any])?["p"] as? [String: Any])?["description"] as? String
            throw Failure.refused(why ?? "no reason given")
        }
        var r = PushRecord(accountId: s.id, label: s.account.label, apiURL: session.apiUrl, mailAccountId: mailAccount, token: token,
                           relayId: relayId, relaySecret: secret, subscriptionId: subId, key: key.rawRepresentation, auth: auth,
                           expires: (made["expires"] as? String).flatMap(Self.date) ?? want, device: device)
        PushRecords.save(r)

        // 3. Fastmail posts a code to the relay; we read it back, open it and hand it to Fastmail to confirm.
        for _ in 0..<15 {
            try await Task.sleep(for: .seconds(2))
            let pending = try await relay("v1/pending", r, method: "GET")
            for case let body as String in (pending["bodies"] as? [Any]) ?? [] {
                guard let data = Data(base64Encoded: body),
                      let plain = try? PushCrypto.decrypt(data, key: key, auth: auth),
                      let notice = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
                      notice["@type"] as? String == "PushVerification",
                      notice["pushSubscriptionId"] as? String == subId,
                      let code = notice["verificationCode"] as? String else { continue }
                let v = try await s.client.call([["PushSubscription/set", ["update": [subId: ["verificationCode": code]]], "v"]],
                                                using: [JMAPClient.core])
                guard (v["v"]?["updated"] as? [String: Any])?.keys.contains(subId) == true else { throw Failure.refused("the code wasn't accepted") }
                _ = try await relay("v1/live", r)
                r.live = true
                PushRecords.save(r)
                return
            }
        }
        throw Failure.noCode
    }

    /// Stops alerts for one account: Fastmail stops posting, the relay forgets the device, and the record goes.
    private func turnOff(_ r: PushRecord) async {
        if let url = URL(string: r.apiURL) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(r.token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "using": [JMAPClient.core], "methodCalls": [["PushSubscription/set", ["destroy": [r.subscriptionId]], "d"]],
            ])
            _ = try? await URLSession.shared.data(for: req)
        }
        _ = try? await relay("v1/delete", r)
        PushRecords.delete(r.accountId)
    }

    // MARK: The relay

    private func register(_ device: String) async throws -> [String: Any] {
        var req = URLRequest(url: Self.relay.appending(path: "v1/register"))
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["device": device, "sandbox": Self.sandbox])
        return try await send(req)
    }

    @discardableResult
    private func relay(_ path: String, _ r: PushRecord, method: String = "POST", body: [String: Any] = [:]) async throws -> [String: Any] {
        var req = URLRequest(url: Self.relay.appending(path: path))
        req.httpMethod = method
        req.setValue("Bearer \(r.relayId).\(r.relaySecret)", forHTTPHeaderField: "Authorization")
        if method == "POST" { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return try await send(req)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        var req = request
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("JMAP Connect iOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let answer = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if code == 503, answer["error"] as? String == "paused" { throw Failure.paused }
        guard code == 200 else { throw Failure.relay(code) }
        return answer
    }

    // MARK: Small helpers

    private static var installId: String {
        if let id = UserDefaults.standard.string(forKey: "installId") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "installId")
        return id
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    private static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}

/// The buttons on a new mail alert. They run in the background with the account's details from the shared
/// Keychain, so they work without opening the app.
enum AlertActions {
    static let category = "newMail"
    static let archive = "archive"
    static let read = "read"

    static func register() {
        let archiveButton = UNNotificationAction(identifier: archive, title: "Archive", options: [],
                                                 icon: UNNotificationActionIcon(systemImageName: "archivebox"))
        let readButton = UNNotificationAction(identifier: read, title: "Mark as read", options: [],
                                              icon: UNNotificationActionIcon(systemImageName: "envelope.open"))
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [archiveButton, readButton], intentIdentifiers: []),
        ])
    }

    static func run(_ action: String, account: String, email: String) async {
        guard let r = PushRecords.read(account), let url = URL(string: r.apiURL) else { return }
        let acct = r.mailAccountId
        func call(_ calls: [[Any]]) async -> [String: [String: Any]] {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 20
            req.setValue("Bearer \(r.token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"], "methodCalls": calls,
            ])
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = root["methodResponses"] as? [[Any]] else { return [:] }
            var out: [String: [String: Any]] = [:]
            for x in list where x.count == 3 { if let id = x[2] as? String, let a = x[1] as? [String: Any] { out[id] = a } }
            return out
        }
        if action == read {
            _ = await call([["Email/set", ["accountId": acct, "update": [email: ["keywords/$seen": true]]], "u"]])
            return
        }
        // Archive the way the app does: take the Inbox label off, and file it in Archive unless it has other labels.
        let got = await call([
            ["Mailbox/get", ["accountId": acct, "properties": ["role"]], "m"],
            ["Email/get", ["accountId": acct, "ids": [email], "properties": ["mailboxIds"]], "e"],
        ])
        let boxes = (got["m"]?["list"] as? [[String: Any]]) ?? []
        func box(_ role: String) -> String? { boxes.first { $0["role"] as? String == role }?["id"] as? String }
        guard let inbox = box("inbox"), let archiveBox = box("archive"),
              let e = (got["e"]?["list"] as? [[String: Any]])?.first,
              let ids = e["mailboxIds"] as? [String: Any], ids[inbox] != nil else { return }
        var patch: [String: Any] = ["mailboxIds/\(inbox)": NSNull(), "keywords/$seen": true]
        if !ids.keys.contains(where: { $0 != inbox && $0 != archiveBox }) { patch["mailboxIds/\(archiveBox)"] = true }
        _ = await call([["Email/set", ["accountId": acct, "update": [email: patch]], "u"]])
    }
}

/// Hands Apple's push address for this device to InstantAlerts.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in InstantAlerts.shared.gotDeviceToken(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in InstantAlerts.shared.deviceTokenFailed() }
    }
}
#endif
