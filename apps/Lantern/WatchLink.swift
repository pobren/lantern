// Apple Watch (1.2): the iPhone hands its Fastmail accounts to the Watch app, which then talks to Fastmail itself,
// so the Watch works on its own Wi-Fi or mobile signal too. Nothing goes through any server of ours.
// WatchConnectivity is encrypted end to end between the paired iPhone and Watch.

#if os(iOS)
import Foundation
import WatchConnectivity

@MainActor
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()
    private weak var store: Store?

    func start(_ store: Store) {
        self.store = store
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        if s.delegate == nil { s.delegate = self }
        if s.activationState == .activated { send() } else { s.activate() }
    }

    /// The accounts as the Watch needs them. Sample mail goes across as a flag, so the Watch shows its own samples.
    private var context: [String: Any] {
        let all = store?.accounts ?? []
        let real = all.filter { $0.account.kind != Demo.kind }.compactMap { s -> [String: String]? in
            guard let token = Keychain.read(s.account.id) else { return nil }
            return ["id": s.account.id, "label": s.account.label, "session": s.account.sessionURL, "token": token]
        }
        return ["accounts": real, "sample": all.contains { $0.account.kind == Demo.kind }, "v": 1]
    }

    func send() {
        let s = WCSession.default
        guard WCSession.isSupported(), s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else { return }
        try? s.updateApplicationContext(context)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.send() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.send() }
    }

    /// The Watch asks again when it opens with no accounts.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            replyHandler(self.context)
        }
    }
}
#endif
