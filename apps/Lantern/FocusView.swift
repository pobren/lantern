// Focus: one email at a time, in the dark, oldest first. Reply, done, later or skip, then the next one.

import SwiftUI

struct FocusView: View {
    @EnvironmentObject var store: Store
    let reply: (Item) -> Void
    @State private var skipped: Set<String> = []
    @State private var text: String?

    private var queue: [Item] { store.focusQueue.filter { !skipped.contains($0.id) } }
    private var current: Item? { queue.first }
    private var total: Int { store.focusDone + skipped.count + queue.count }
    private var progress: Double { total == 0 ? 1 : Double(total - queue.count) / Double(total) }

    var body: some View {
        ZStack {
            Look.night.ignoresSafeArea()
            if let item = current {
                VStack(spacing: 0) {
                    top
                    ScrollView {
                        card(item).padding(.horizontal, 60).padding(.vertical, 30)
                    }
                    actions(item)
                }
                .id(item.id)
                .task { text = nil; text = await store.body(item) }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.circle").font(.system(size: 54, weight: .light)).foregroundStyle(Look.nightAccent)
                    Text("You're through it all.").font(Look.display(30)).foregroundStyle(Look.nightInk)
                    Text("Nothing unread is waiting. New mail will show up here when it lands.").foregroundStyle(Look.nightMuted)
                    if !skipped.isEmpty {
                        Button { skipped = [] } label: { Label("Go back to the \(skipped.count) you skipped", systemImage: "arrow.uturn.backward") }
                            .buttonStyle(.bordered).padding(.top, 8)
                    }
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var top: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Focus", systemImage: "scope").font(.system(size: 13, weight: .semibold)).foregroundStyle(Look.nightAccent)
                Spacer()
                Text("\(queue.count) left").font(.system(size: 13)).foregroundStyle(Look.nightMuted)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Look.nightRaised)
                    Capsule().fill(Look.nightAccent).frame(width: g.size.width * progress)
                }
            }
            .frame(height: 4)
            .animation(.easeOut, value: progress)
        }
        .padding(.horizontal, 60).padding(.top, 26)
    }

    private func card(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Avatar(address: item.email.sender, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.email.sender.display).font(.system(size: 16, weight: .semibold)).foregroundStyle(Look.nightInk)
                    Text("\(item.email.sender.email) · \(When.short(item.email.date))").font(.system(size: 12.5)).foregroundStyle(Look.nightMuted)
                }
                Spacer()
                HStack(spacing: 6) { AccountDot(account: item.account); Text(item.account.label) }
                    .font(.caption).foregroundStyle(Look.nightMuted)
            }
            Text(item.email.title).font(Look.display(28)).foregroundStyle(Look.nightInk)
            Text(text ?? item.email.preview ?? "")
                .font(.system(size: 15.5)).lineSpacing(5).foregroundStyle(Look.nightInk.opacity(0.88))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if text == nil { ProgressView().controlSize(.small) }
        }
        .padding(34)
        .frame(maxWidth: 760)
        .background(RoundedRectangle(cornerRadius: 20).fill(Look.nightCard))
        .frame(maxWidth: .infinity)
    }

    private func actions(_ item: Item) -> some View {
        HStack(spacing: 10) {
            key("Reply", "R", "arrowshape.turn.up.left", primary: true) { reply(item) }
                .keyboardShortcut("r", modifiers: [])
            key("Done", "E", "checkmark") { Task { store.focusDone += 1; await store.done(item) } }
                .keyboardShortcut("e", modifiers: [])
            key("Later", "L", "clock") { store.focusDone += 1; store.putOff(item) }
                .keyboardShortcut("l", modifiers: [])
            key("Skip", "S", "forward") { skipped.insert(item.id) }
                .keyboardShortcut("s", modifiers: [])
            key("Read", "Space", "envelope.open") { Task { store.focusDone += 1; skipped.insert(item.id); await store.markRead(item) } }
                .keyboardShortcut(.space, modifiers: [])
        }
        .padding(.bottom, 26).padding(.top, 6)
    }

    private func key(_ title: String, _ hint: String, _ icon: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title).fontWeight(.semibold)
                Text(hint).font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(primary ? 0.22 : 0.08)))
            }
            .font(.system(size: 13.5))
            .foregroundStyle(primary ? Look.night : Look.nightInk)
            .padding(.horizontal, 16).frame(height: 40)
            .background(Capsule().fill(primary ? Look.nightAccent : Look.nightRaised))
        }
        .buttonStyle(.plain)
        .help("\(title) (\(hint))")
    }
}
