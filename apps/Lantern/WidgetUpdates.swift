// Keeps the Home Screen and Lock Screen widgets up to date: after the inbox loads or changes, the app saves the unread
// count and latest emails where the widget can read them, and asks it to redraw (iPhone and iPad).

import Foundation
#if os(iOS)
import WidgetKit
#endif

extension Store {
    func saveWidget() {
        #if os(iOS)
        let shown = shownAccounts.filter { !isSample($0) }
        let unread = shown.reduce(0) { $0 + ($1.box("inbox")?.unreadEmails ?? 0) }
        let latest = shown.flatMap { s in s.inbox.map { (s, $0) } }
            .sorted { $0.1.date > $1.1.date }
            .prefix(8)
            .map { s, e in WidgetSnapshot.Mail(id: e.id, account: s.account.label, sender: e.sender.display,
                                               subject: e.title, date: e.date, unread: e.isUnread) }
        WidgetStore.save(WidgetSnapshot(unread: unread, latest: Array(latest), saved: Date()))
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
