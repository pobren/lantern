// Newsletter manager (Paul, 21 Nov 2026). One page listing every mailing list that's emailed you in the last three
// months: how often it sends, how many you actually read, and buttons to unsubscribe or clear them all out of the
// inbox. It uses the List-Unsubscribe line every newsletter carries and the app's usual JMAP search, so it works on
// Fastmail and any other JMAP server, with nothing new on our side. Can be turned off in Settings.

import SwiftUI

struct Newsletter: Identifiable, Hashable {
    let id: String          // account id + sender address
    let account: Account
    let name: String
    let email: String
    var emails: [Email]

    var count: Int { emails.count }
    var read: Int { emails.filter { !$0.isUnread }.count }
    var latest: Email? { emails.max { $0.date < $1.date } }
    var sender: EmailAddress { EmailAddress(name: name, email: email) }

    /// "About 3 a week", "About 2 a month", from the last 13 weeks.
    var rate: String {
        let perWeek = Double(count) / 13
        if perWeek >= 6.5 { return String(localized: "About \(Int((perWeek / 7).rounded())) a day") }
        if perWeek >= 0.9 { return String(localized: "About \(Int(perWeek.rounded())) a week") }
        let perMonth = Int((Double(count) / 3).rounded())
        return perMonth <= 1 ? "Now and then" : String(localized: "About \(perMonth) a month")
    }

    /// How much of it you read, for sorting the ones you never open to the top.
    var readShare: Double { count == 0 ? 0 : Double(read) / Double(count) }
}

enum NewsletterSort: String, CaseIterable, Identifiable {
    case mostOften = "Most often", leastRead = "Least read", name = "Name"
    var id: String { rawValue }
}

@MainActor
final class NewslettersModel: ObservableObject {
    static let key = "newsletterManager"
    @Published var all: [Newsletter] = []
    @Published var loading = false
    @Published var problem: String?
    @Published var chosen: Newsletter.ID?
    @Published var sort: NewsletterSort = .mostOften
    @Published var done: [String: String] = [:]     // newsletter id: what was done ("Unsubscribed", "Archived 12")
    @Published var working: Set<String> = []

    var shown: [Newsletter] {
        switch sort {
        case .mostOften: return all.sorted { $0.count > $1.count }
        case .leastRead: return all.sorted { ($0.readShare, -$0.count) < ($1.readShare, -$1.count) }
        case .name: return all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    var chosenOne: Newsletter? { chosen.flatMap { id in all.first { $0.id == id } } }

    func load(_ store: Store) async {
        guard !loading else { return }
        loading = true
        problem = nil
        defer { loading = false }
        let since = Email.isoPlain.string(from: Date().addingTimeInterval(-91 * 86_400))
        let accounts = store.shownAccounts.filter { !store.isSample($0) }
        // Outside the page's own task, so a redraw can't stop it half way (as happened with Contacts).
        let found = await Task { @MainActor () -> ([Newsletter], String?) in
            var groups: [String: Newsletter] = [:]
            var problem: String?
            for s in accounts {
                do {
                    let skip = [s.box("trash")?.id, s.box("junk")?.id].compactMap { $0 }
                    var filter: [String: Any] = ["header": ["List-Unsubscribe"], "after": since]
                    if !skip.isEmpty { filter = ["operator": "AND", "conditions": [filter, ["inMailboxOtherThan": skip]]] }
                    let emails = try await s.client.emails(filter: filter, limit: 1000, collapseThreads: false)
                    for e in emails {
                        let address = e.sender.email.lowercased()
                        guard !address.isEmpty else { continue }
                        let id = s.id + "/" + address
                        if groups[id] == nil {
                            groups[id] = Newsletter(id: id, account: s.account, name: e.sender.display, email: e.sender.email, emails: [])
                        }
                        groups[id]?.emails.append(e)
                    }
                } catch {
                    let ns = error as NSError
                    if !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) { problem = error.localizedDescription }
                }
            }
            return (Array(groups.values), problem)
        }.value
        all = found.0
        problem = found.1
        #if os(macOS)
        if chosen == nil { chosen = shown.first?.id }
        #endif
    }

    func unsubscribe(_ n: Newsletter, store: Store, openURL: (URL) -> Void) async {
        guard let latest = n.latest else { return }
        working.insert(n.id)
        defer { working.remove(n.id) }
        guard let u = await store.unsubscribe(latest, account: n.account) else {
            done[n.id] = "No unsubscribe link found"
            return
        }
        if let url = u.oneClick, (try? await JMAPClient.oneClickUnsubscribe(url)) != nil {
            done[n.id] = "Unsubscribed"
        } else if let url = u.web {
            openURL(url)
            done[n.id] = "Unsubscribe page opened"
        } else if u.mail != nil {
            done[n.id] = "Unsubscribe by email from the newsletter itself"
        }
    }

    /// Archives (or bins) every email from this newsletter that's still in the inbox. One Undo puts them back.
    func clearInbox(_ n: Newsletter, store: Store, bin: Bool) async {
        guard let s = store.state(for: n.account), let inbox = s.box("inbox") else { return }
        working.insert(n.id)
        defer { working.remove(n.id) }
        let inInbox = n.emails.filter { $0.mailboxIds[inbox.id] == true }
        guard !inInbox.isEmpty else { done[n.id] = "None left in the inbox"; return }
        UndoMove.shared.startCollecting()
        for e in inInbox {
            let item = Item(account: n.account, email: e)
            if bin { await store.delete(item) } else { await store.archive(item) }
        }
        let what = bin ? "Deleted" : "Archived"
        UndoMove.shared.finishCollecting(title: "\(what) \(inInbox.count) from \(n.name)")
        done[n.id] = "\(what) \(inInbox.count)"
        await store.refresh()
    }
}

/// The middle column when Newsletters is chosen in the sidebar.
struct NewslettersList: View {
    @EnvironmentObject var store: Store
    @ObservedObject var model: NewslettersModel

    var body: some View {
        List(selection: $model.chosen) {
            if let problem = model.problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
            if !model.loading && model.all.isEmpty && model.problem == nil {
                Text("No newsletters in the last three months.").foregroundStyle(.secondary)
            }
            if !model.all.isEmpty {
                Section {
                    ForEach(model.shown) { n in
                        HStack(spacing: 12) {
                            Avatar(address: n.sender, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(n.name).font(Look.size(15, weight: .semibold)).lineLimit(1)
                                Text("\(n.rate) · you read \(n.read) of \(n.count)")
                                    .font(Look.size(13)).foregroundStyle(.secondary).lineLimit(1)
                                if let d = model.done[n.id] {
                                    Label(d, systemImage: "checkmark.circle").font(.caption).foregroundStyle(Look.other)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                        // A fixed minimum keeps the Mac's table from measuring rows before their text is in.
                        .frame(minHeight: 56, alignment: .leading)
                        .tag(n.id)
                    }
                } header: {
                    Text("\(model.all.count) newsletters in the last three months")
                }
            }
        }
        // On the Mac the list is built once with no rows and then keeps squashed row heights when the
        // newsletters arrive (Paul, 26 Nov), so it starts afresh each time the list of senders changes.
        .id(model.all.map(\.id))
        .overlay { if model.loading && model.all.isEmpty { ProgressView() } }
        .navigationTitle("Newsletters")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort", selection: $model.sort) {
                        ForEach(NewsletterSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.load(store) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .task { if model.all.isEmpty { await model.load(store) } }
    }
}

/// The right-hand column: one newsletter, with its buttons and its latest emails.
struct NewsletterDetail: View {
    @EnvironmentObject var store: Store
    @Environment(\.openURL) private var openURL
    @ObservedObject var model: NewslettersModel
    let open: (MessageRef) -> Void
    @State private var confirmBin = false

    var body: some View {
        if let n = model.chosenOne {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 6) {
                        Avatar(address: n.sender, size: 84).padding(.bottom, 4)
                        Text(n.name).font(Look.size(24, weight: .bold)).multilineTextAlignment(.center)
                        Text(n.email).font(Look.size(14)).foregroundStyle(.secondary).textSelection(.enabled)
                        if store.accounts.count > 1 { Text(n.account.label).font(.caption).foregroundStyle(.secondary) }
                    }
                    HStack(spacing: 12) {
                        stat("\(n.count)", "in 3 months")
                        stat(n.rate.replacingOccurrences(of: "About ", with: ""), "how often")
                        stat("\(Int((n.readShare * 100).rounded()))%", "you read")
                    }
                    .frame(maxWidth: 460)
                    if let d = model.done[n.id] {
                        Label(d, systemImage: "checkmark.circle.fill").foregroundStyle(Look.other)
                    }
                    HStack(spacing: 10) {
                        Button { Task { await model.unsubscribe(n, store: store) { openURL($0) } } } label: {
                            Label("Unsubscribe", systemImage: "hand.raised.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button { Task { await model.clearInbox(n, store: store, bin: false) } } label: {
                            Label("Archive all", systemImage: "archivebox").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        Button(role: .destructive) { confirmBin = true } label: {
                            Label("Delete all", systemImage: "trash").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(Look.softRed)
                    }
                    .controlSize(.large)
                    .disabled(model.working.contains(n.id))
                    .frame(maxWidth: 520)
                    Text("Archive all and Delete all only touch this sender's emails still in your inbox. Undo puts them back.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Latest emails").font(Look.size(13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                        VStack(alignment: .leading, spacing: 10) {
                            let recent = Array(n.emails.sorted { $0.date > $1.date }.prefix(15))
                            ForEach(recent) { e in
                                Button { open(MessageRef(account: n.account.id, email: e.id)) } label: {
                                    HStack(alignment: .firstTextBaseline) {
                                        if e.isUnread { Circle().fill(Look.accent).frame(width: 7, height: 7) }
                                        Text(e.title).font(Look.size(14.5, weight: e.isUnread ? .semibold : .regular)).lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text(When.short(e.date)).font(Look.size(12.5)).foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if e.id != recent.last?.id { Divider() }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Look.ground))
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 28)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background(Look.paper)
            .navigationTitle(n.name)
            .confirmationDialog("Delete every email from \(n.name) in your inbox?", isPresented: $confirmBin, titleVisibility: .visible) {
                Button(role: .destructive) { Task { await model.clearInbox(n, store: store, bin: true) } } label: { Label("Delete all", systemImage: "trash") }
                Button("Cancel", role: .cancel) {}
            } message: { Text("They go to the Bin, and Undo puts them back.") }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "newspaper").font(Look.size(34, weight: .light)).foregroundStyle(.tertiary)
                Text("No newsletter selected").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(Look.size(17, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(Look.size(12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Look.ground))
    }
}
