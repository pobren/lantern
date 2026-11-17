// Today: the home screen. No list of mail; your inbox sorted into what needs you, updates, and reading for later.

import SwiftUI

struct TodayView: View {
    @EnvironmentObject var store: Store
    let open: (Item) -> Void
    let reply: (Item) -> Void

    private var name: String {
        let n = store.accounts.flatMap(\.identities).first?.name ?? ""
        return n.split(separator: " ").first.map(String.init) ?? ""
    }

    private var headline: String {
        let people = Set(store.needsYou.map { $0.email.sender.email.lowercased() }).count
        switch people {
        case 0: return "Nobody is waiting on you. Enjoy the quiet."
        case 1: return "One person is waiting on you. Everything else can wait."
        default: return "\(people) people are waiting on you. Everything else can wait."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                HStack(alignment: .top, spacing: 22) {
                    needsYou.frame(maxWidth: .infinity)
                    updates.frame(maxWidth: .infinity)
                    reading.frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 44).padding(.vertical, 36)
        }
        .background(Look.ground)
        .refreshable { await store.refresh() }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(When.today()).font(.system(size: 13, weight: .semibold)).foregroundStyle(Look.muted).tracking(0.3)
                Text(name.isEmpty ? "\(When.greeting())." : "\(When.greeting()), \(name).").font(Look.display(42)).foregroundStyle(Look.ink)
                Text(headline).font(.system(size: 16)).foregroundStyle(Color(white: 0.25))
            }
            Spacer()
            HStack(spacing: 8) {
                ForEach(store.accounts) { s in
                    HStack(spacing: 7) { AccountDot(account: s.account); Text(s.account.label) }
                        .font(.system(size: 12.5)).padding(.horizontal, 12).frame(height: 30)
                        .background(Capsule().fill(Color.white)).overlay(Capsule().stroke(Look.line))
                }
            }
        }
    }

    private func heading(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13, weight: .bold))
            if let count, count > 0 {
                Text("\(count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).frame(height: 20).background(Capsule().fill(Look.accent))
            }
        }
    }

    private var needsYou: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Needs you", count: store.needsYou.count)
            if store.needsYou.isEmpty {
                Card { Text("All clear. Replies and new conversations show up here.").foregroundStyle(Look.muted) }
            }
            ForEach(store.needsYou.prefix(8)) { item in
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Avatar(address: item.email.sender)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.email.sender.display).font(.system(size: 14, weight: .semibold))
                                Text(When.short(item.email.date)).font(.caption).foregroundStyle(Look.muted)
                            }
                            Spacer()
                            AccountDot(account: item.account)
                        }
                        Button { open(item) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.email.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Look.ink)
                                Text(item.email.preview ?? "").font(.system(size: 13)).foregroundStyle(Color(white: 0.25)).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        HStack(spacing: 6) {
                            PillButton(title: "Reply", icon: "arrowshape.turn.up.left", primary: true) { reply(item) }
                            PillButton(title: "Later", icon: "clock") { store.putOff(item) }
                            PillButton(title: "Done", icon: "checkmark") { Task { await store.done(item) } }
                        }
                    }
                }
            }
        }
    }

    private var updates: some View {
        let items = store.pile(.updates)
        return VStack(alignment: .leading, spacing: 12) {
            heading("Updates and receipts")
            VStack(spacing: 0) {
                if items.isEmpty {
                    Text("Nothing new.").foregroundStyle(Look.muted).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                ForEach(items.prefix(10)) { item in
                    Button { open(item) } label: {
                        HStack(spacing: 12) {
                            Avatar(address: item.email.sender, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.email.sender.display).font(.system(size: 13, weight: item.email.isUnread ? .semibold : .regular))
                                Text(item.email.title).font(.system(size: 12.5)).foregroundStyle(Look.muted).lineLimit(1)
                            }
                            Spacer()
                            Text(When.short(item.email.date)).font(.system(size: 11.5)).foregroundStyle(Look.muted)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().opacity(0.5)
                }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Look.line))
            if items.contains(where: { $0.email.isUnread }) {
                Button { Task { await store.markAllSeen(items) } } label: { Label("Mark all as seen", systemImage: "checkmark") }
                    .buttonStyle(.borderless).frame(maxWidth: .infinity)
            }
        }
    }

    private var reading: some View {
        let items = store.pile(.reading)
        return VStack(alignment: .leading, spacing: 12) {
            heading("For later reading")
            if items.isEmpty { Card { Text("Newsletters land here, out of your way.").foregroundStyle(Look.muted) } }
            ForEach(items.prefix(6)) { item in
                let (bg, fg) = Look.tint(for: item.email.sender.email)
                Button { open(item) } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.email.title)
                            .font(Look.display(18)).foregroundStyle(fg).lineLimit(3)
                            .frame(maxWidth: .infinity, minHeight: 92, alignment: .bottomLeading)
                            .padding(14).background(bg)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.email.sender.display).font(.system(size: 12.5, weight: .semibold))
                            Text(item.email.preview ?? "").font(.system(size: 12.5)).foregroundStyle(Look.muted).lineLimit(2)
                        }
                        .padding(14)
                    }
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Look.line))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
