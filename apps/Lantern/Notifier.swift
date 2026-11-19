// New mail notifications and the unread badge.
// On Mac, Lantern hears about new mail the moment it arrives (JMAP push) while it's open. On iPhone and iPad it
// also checks in the background when iOS lets it, usually every 15 minutes or so; with instant alerts switched on,
// Fastmail's notices come through our relay (see InstantAlerts.swift).

import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
enum Notifier {
    static let enabledKey = "notifications"
    static let badgeKey = "badge"

    private static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    private static var showBadge: Bool { UserDefaults.standard.object(forKey: badgeKey) as? Bool ?? true }

    static func ask() async {
        guard enabled, !Demo.launchedForScreens else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Tells you about unread emails that arrived since the last check. The very first check only sets the mark,
    /// so adding an account doesn't set off a flood of old mail.
    static func newMail(in inbox: [Email], account: Account) {
        let key = "notified-" + account.id
        let newest = inbox.map(\.date).max() ?? Date()
        guard let last = UserDefaults.standard.object(forKey: key) as? Date else {
            UserDefaults.standard.set(newest, forKey: key)
            return
        }
        let fresh = inbox.filter { $0.isUnread && $0.date > last }.sorted { $0.date < $1.date }
        guard !fresh.isEmpty else { return }
        UserDefaults.standard.set(max(newest, last), forKey: key)
        guard enabled else { return }

        let center = UNUserNotificationCenter.current()
        if fresh.count > 4 {
            let content = UNMutableNotificationContent()
            content.title = "\(fresh.count) new emails"
            content.body = fresh.suffix(3).reversed().map { "\($0.sender.display): \($0.title)" }.joined(separator: "\n")
            content.sound = .default
            content.threadIdentifier = account.id
            center.add(UNNotificationRequest(identifier: "batch-\(account.id)-\(Int(newest.timeIntervalSince1970))", content: content, trigger: nil))
            return
        }
        // Instant alerts may already have shown some of these: skip any already on screen.
        Task {
            let shown = Set(await center.deliveredNotifications().compactMap { $0.request.content.userInfo["email"] as? String })
            for e in fresh where !shown.contains(e.id) {
                post(e, account: account, center: center)
            }
        }
    }

    private static func post(_ e: Email, account: Account, center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = e.sender.display
        content.subtitle = e.title
        content.body = e.preview ?? ""
        content.sound = .default
        content.threadIdentifier = account.id + "/" + e.threadId
        content.userInfo = ["account": account.id, "email": e.id]
        center.add(UNNotificationRequest(identifier: account.id + "/" + e.id, content: content, trigger: nil))
    }

    /// The unread count on the app icon (Dock on Mac, home screen on iPhone and iPad).
    static func badge(_ unread: Int) {
        let n = showBadge ? unread : 0
        #if os(macOS)
        NSApp?.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
        #else
        UNUserNotificationCenter.current().setBadgeCount(n) { _ in }
        #endif
    }
}

/// Shows notifications even while Lantern is open.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
