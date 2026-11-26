// Focus filters (Paul, 21 Nov 2026). In Settings > Focus, each Focus (Work, Personal and so on) can pick which mail
// accounts JMAP Connect shows. In the Work Focus, say, only the work account's folders and inbox show; when the
// Focus ends, everything comes back. Nothing leaves the device.

import AppIntents
import SwiftUI

/// One of your mail accounts, for the Focus settings.
struct MailAccountEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Mail account"
    static var defaultQuery = MailAccountQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct MailAccountQuery: EntityQuery {
    static func saved() -> [MailAccountEntity] {
        let data = UserDefaults.standard.data(forKey: "accounts")
        let accounts = data.flatMap { try? JSONDecoder().decode([Account].self, from: $0) } ?? []
        return accounts.map { MailAccountEntity(id: $0.id, name: $0.label) }
    }
    func entities(for identifiers: [String]) async throws -> [MailAccountEntity] {
        Self.saved().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [MailAccountEntity] { Self.saved() }
}

struct MailFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Show accounts"
    static var description: IntentDescription? = "Choose which mail accounts JMAP Connect shows while this Focus is on."

    @Parameter(title: "Accounts") var accounts: [MailAccountEntity]?

    var displayRepresentation: DisplayRepresentation {
        let names = (accounts ?? []).map(\.name)
        return DisplayRepresentation(title: names.isEmpty ? "All accounts" : "\(names.joined(separator: ", "))")
    }

    func perform() async throws -> some IntentResult {
        let ids = (accounts ?? []).map(\.id)
        UserDefaults.standard.set(ids, forKey: FocusAccounts.key)
        await MainActor.run { NotificationCenter.default.post(name: FocusAccounts.changed, object: nil) }
        return .result()
    }
}

enum FocusAccounts {
    static let key = "focusAccounts"
    static let changed = Notification.Name("lanternFocusChanged")
    /// The accounts the current Focus shows, or nil for all of them.
    static var only: Set<String>? {
        let ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        return ids.isEmpty ? nil : Set(ids)
    }
}

extension Store {
    /// The accounts on show: all of them, or only the ones the current Focus picked.
    var shownAccounts: [AccountState] {
        guard let only = FocusAccounts.only else { return accounts }
        let picked = accounts.filter { only.contains($0.id) }
        return picked.isEmpty ? accounts : picked
    }

    /// True while a Focus is hiding some accounts (the sidebar says so).
    var focusHidesAccounts: Bool { shownAccounts.count < accounts.count }
}
