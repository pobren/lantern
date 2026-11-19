// Offline mail: keeping the copy on the device (Cache.swift) filled and up to date, showing it when there's no
// connection, and sending what was done offline once the connection is back.
//
// How the copy is kept:
// - The first time, every email's list details (sender, subject, preview, folders) are fetched, newest first, a
//   page at a time. If the app closes part way, it carries on from the same place next time.
// - After that, JMAP's Email/changes says exactly what changed since last time, so catching up is quick.
// - The full text of recent emails (3 months on iPhone and iPad, 12 on a Mac, changeable in Settings) is fetched
//   in the background, only on Wi-Fi or other unmetered connections, for reading and searching offline.
// Sample mail is never saved.

import Foundation
import Network

/// Watches the connection coming and going.
final class NetworkWatch {
    private let monitor = NWPathMonitor()

    init(_ changed: @escaping @Sendable (_ up: Bool) -> Void) {
        monitor.pathUpdateHandler = { path in changed(path.status == .satisfied) }
        monitor.start(queue: DispatchQueue(label: "dev.paulobrien.lantern.network"))
    }

    /// Mobile data, a personal hotspot or Low Data Mode: no background downloads of full emails.
    var metered: Bool { monitor.currentPath.isExpensive || monitor.currentPath.isConstrained }

    deinit { monitor.cancel() }
}

extension Store {
    nonisolated static let offlineMonthsKey = "offlineMonths"

    /// How many months of full emails to keep on the device; 0 means all of them.
    nonisolated static var offlineMonths: Int {
        if let n = UserDefaults.standard.object(forKey: offlineMonthsKey) as? Int { return n }
        #if os(macOS)
        return 12
        #else
        return 3
        #endif
    }

    func isSample(_ s: AccountState) -> Bool { s.account.kind == Demo.kind }

    /// Errors that mean "no connection", as opposed to the server saying no.
    nonisolated static func isOffline(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        let codes: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                                      .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive]
        return codes.contains(e.code)
    }

    /// Shows an error, unless it only means there's no connection: then the app quietly works offline.
    func report(_ s: AccountState, _ error: Error, quietly: Bool = false) {
        if Self.isOffline(error) { goOffline(); return }
        if !quietly { problem = "\(s.account.label): \(error.localizedDescription)" }
    }

    func goOffline() {
        if !offline { offline = true }
    }

    func backOnline() {
        guard offline else { return }
        offline = false
        Task { await sendWaiting() }
    }

    func watchNetwork() {
        guard network == nil else { return }
        network = NetworkWatch { [weak self] up in
            Task { @MainActor in
                guard let self else { return }
                if !up { self.goOffline(); return }
                guard self.offline else { return }
                await self.refresh()
                for s in self.accounts { self.keepSynced(s) }
                await self.sendWaiting()
            }
        }
    }

    // MARK: Showing what's saved

    /// Folders, addresses and inboxes from the device, so the app has something to show before the server answers.
    func loadSaved() async {
        for s in accounts where !isSample(s) {
            if s.mailboxes.isEmpty, let boxes = await cache.value([Mailbox].self, "mailboxes", account: s.id) { s.mailboxes = boxes }
            if s.identities.isEmpty, let ids = await cache.value([Identity].self, "identities", account: s.id) { s.identities = ids }
            if s.inbox.isEmpty, let inbox = s.box("inbox") { s.inbox = await cache.list(box: inbox.id, account: s.id, limit: 100) }
        }
        objectWillChange.send()
        await countOutbox()
        if list.isEmpty {
            let saved = await savedItems(words: "", folder: folder, scope: searchScope, limit: 100)
            if list.isEmpty && !saved.isEmpty { list = saved }
        }
    }

    /// Saves an account's folders, addresses and inbox after the server sends them.
    func remember(_ s: AccountState) async {
        guard !isSample(s) else { return }
        await cache.saveValue(s.mailboxes, as: "mailboxes", account: s.id)
        await cache.saveValue(s.identities, as: "identities", account: s.id)
        await cache.save(s.inbox, account: s.id)
    }

    func remember(_ items: [Item]) async {
        for (id, group) in Dictionary(grouping: items, by: { $0.account.id }) {
            guard let s = state(id: id), !isSample(s) else { continue }
            await cache.save(group.map(\.email), account: id)
        }
    }

    func remember(_ emails: [Email], in s: AccountState) async {
        guard !isSample(s) else { return }
        await cache.save(emails, account: s.id)
    }

    // MARK: Changes made offline

    /// Read, star, move and delete: saved on the device straight away, sent to the server now, or kept until the
    /// connection is back.
    func apply(_ patches: [String: [String: Any]], in s: AccountState) async {
        guard !patches.isEmpty else { return }
        if !isSample(s) {
            let saved = await cache.emails(ids: Array(patches.keys), account: s.id)
            await cache.save(saved.map { $0.patched(patches[$0.id] ?? [:]) }, account: s.id)
        }
        do {
            try await s.client.update(patches)
            backOnline()
        } catch {
            if Self.isOffline(error) && !isSample(s) {
                goOffline()
                if let data = try? JSONSerialization.data(withJSONObject: patches) {
                    await cache.queue(Pending(account: s.id, kind: "update", data: data))
                }
                return
            }
            report(s, error)
        }
        // Unread counts and folders come back from the server; the list itself was already changed on screen.
        if let boxes = try? await s.client.mailboxes() { s.mailboxes = boxes; objectWillChange.send() }
    }

    /// Sends everything waiting, oldest first. Stops at the first sign the connection has gone again.
    func sendWaiting() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        for p in await cache.pending() {
            guard let s = state(id: p.account) else { await cache.done(p); continue }
            do {
                switch p.kind {
                case "update":
                    if let patches = try JSONSerialization.jsonObject(with: p.data) as? [String: [String: Any]] {
                        try await s.client.update(patches)
                    }
                case "send":
                    let m = try JSONDecoder().decode(OutboxEmail.self, from: p.data)
                    guard let identity = s.identities.first(where: { $0.id == m.identityId }),
                          let drafts = s.box("drafts"), let sent = s.box("sent") else { throw JMAPError.missing("the address it was written from") }
                    try await s.client.send(from: identity, as: m.address, to: m.to, cc: m.cc, bcc: m.bcc, subject: m.subject, text: m.text,
                                            inReplyTo: m.inReplyTo, references: m.references,
                                            attachments: m.attachments.map { Outgoing(blobId: $0.blobId, name: $0.name, type: $0.type, size: $0.size) },
                                            drafts: drafts.id, sent: sent.id, replacing: m.replacing)
                default: break
                }
                await cache.done(p)
            } catch {
                if Self.isOffline(error) { goOffline(); break }
                // The server said no (the email was deleted elsewhere, say). Drop it so it doesn't hold up the rest.
                await cache.done(p)
                if p.kind == "send" { problem = "An email in the Outbox couldn't be sent: \(error.localizedDescription)" }
            }
        }
        await countOutbox()
        for s in accounts { keepSynced(s) }
    }

    func countOutbox() async {
        outbox = await cache.pending().filter { $0.kind == "send" }.count
    }

    // MARK: Keeping the copy up to date

    /// Starts catching up in the background, or asks a running catch up to go round once more.
    func keepSynced(_ s: AccountState) {
        guard !isSample(s) else { return }
        let id = s.id
        guard syncs[id] == nil else { resync.insert(id); return }
        syncs[id] = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.resync.remove(id)
                await self.sync(id)
            } while self.resync.contains(id) && !Task.isCancelled
            self.syncs[id] = nil
        }
    }

    private func sync(_ id: String) async {
        guard let s = state(id: id) else { return }
        do {
            if s.client.session == nil { try await s.client.connect() }
            if let state = await cache.meta("emailState", account: id) {
                try await catchUp(from: state, s)
            } else {
                try await fillAll(s)
            }
            try await fillBodies(s)
            backOnline()
        } catch {
            if case JMAPError.method(let type, _) = error, type == "cannotCalculateChanges" {
                // The server has forgotten where we were: start the copy again.
                await cache.clear(account: id)
                await remember(s)
                resync.insert(id)
            } else {
                report(s, error, quietly: true)
            }
        }
    }

    /// The first fill: every email's list details, newest first, a page at a time, carrying on where it left off.
    private func fillAll(_ s: AccountState) async throws {
        let id = s.id
        let page = 200
        var start = await cache.meta("fillState", account: id)
        if start == nil {
            let state = try await s.client.emailState()
            await cache.setMeta("fillState", state, account: id)
            start = state
        }
        var anchor = await cache.meta("fillAnchor", account: id)
        while !Task.isCancelled {
            let emails: [Email]
            do {
                emails = try await s.client.allEmails(after: anchor, limit: page)
            } catch JMAPError.method(let type, _) where type == "anchorNotFound" {
                anchor = nil   // that email has gone since last time; start again from the top (saving is cheap)
                continue
            }
            await cache.save(emails, account: id)
            guard emails.count == page, let last = emails.last?.id else { break }
            anchor = last
            await cache.setMeta("fillAnchor", last, account: id)
        }
        guard !Task.isCancelled, let start else { return }
        await cache.setMeta("emailState", start, account: id)
        await cache.setMeta("fillAnchor", nil, account: id)
        await cache.setMeta("fillState", nil, account: id)
        // Anything that changed while the fill was running.
        try await catchUp(from: start, s)
    }

    /// Fetches what changed since last time.
    private func catchUp(from state: String, _ s: AccountState) async throws {
        let id = s.id
        var since = state
        while !Task.isCancelled {
            let c = try await s.client.emailChanges(since: since)
            var i = 0
            while i < c.changed.count {
                let chunk = Array(c.changed[i..<min(i + 200, c.changed.count)])
                await cache.save(try await s.client.emails(ids: chunk), account: id)
                i += 200
            }
            await cache.remove(ids: c.removed, account: id)
            since = c.state
            await cache.setMeta("emailState", since, account: id)
            if !c.more { break }
        }
    }

    /// The full text of recent emails, for reading and searching offline. Skipped on metered connections.
    private func fillBodies(_ s: AccountState) async throws {
        if network?.metered == true { return }
        let id = s.id
        let months = Self.offlineMonths
        let since = months == 0 ? Date.distantPast : (Calendar.current.date(byAdding: .month, value: -months, to: Date()) ?? Date())
        if months > 0 { await cache.trimBodies(before: since) }
        while !Task.isCancelled {
            let ids = await cache.missingBodies(account: id, since: since, limit: 20)
            if ids.isEmpty { break }
            let got = try await s.client.contents(of: ids)
            for e in ids {
                // An email the server no longer has gets an empty page, so it isn't asked for again.
                await cache.savePage(got[e] ?? SavedPage(html: "", text: "", attachments: [], complete: false), id: e, account: id)
            }
            if network?.metered == true { return }
        }
    }

    // MARK: Settings

    func savedSize() async -> Int64 { await cache.size() }

    /// Forgets everything saved on the device (not what's waiting to send) and starts the copy again.
    func clearSaved() async {
        for (_, task) in syncs { task.cancel() }
        syncs = [:]
        await cache.clear()
        clearPages()
        for s in accounts { await remember(s) }
        for s in accounts { keepSynced(s) }
    }

    /// The window in Settings changed: trim or fill to match.
    func offlineWindowChanged() {
        for s in accounts { keepSynced(s) }
    }
}

extension Email {
    /// A copy with JMAP patches applied ("keywords/$seen": true, "mailboxIds/abc": null, or a whole "mailboxIds").
    func patched(_ patch: [String: Any]) -> Email {
        var k = keywords ?? [:]
        var m = mailboxIds
        for (key, value) in patch {
            let on = (value as? Bool) == true
            if key == "mailboxIds", let all = value as? [String: Bool] {
                m = all
            } else if key.hasPrefix("keywords/") {
                let name = String(key.dropFirst("keywords/".count))
                if on { k[name] = true } else { k.removeValue(forKey: name) }
            } else if key.hasPrefix("mailboxIds/") {
                let box = String(key.dropFirst("mailboxIds/".count))
                if on { m[box] = true } else { m.removeValue(forKey: box) }
            }
        }
        return Email(id: id, threadId: threadId, mailboxIds: m, keywords: k, from: from, to: to, cc: cc,
                     replyTo: replyTo, subject: subject, preview: preview, receivedAt: receivedAt,
                     hasAttachment: hasAttachment, messageId: messageId, references: references, blobId: blobId,
                     bcc: bcc, inReplyTo: inReplyTo)
    }
}
