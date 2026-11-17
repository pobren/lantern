// Reading one email: who it's from, the words, and what to do with it.

import SwiftUI

struct MessageView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let item: Item
    let onReply: () -> Void
    @State private var text: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                PillButton(title: "Reply", icon: "arrowshape.turn.up.left", primary: true) { dismiss(); onReply() }
                PillButton(title: "Done", icon: "checkmark") { Task { await store.done(item); dismiss() } }
                PillButton(title: "Later", icon: "clock") { store.putOff(item); dismiss() }
                PillButton(title: item.email.isFlagged ? "Unstar" : "Star", icon: item.email.isFlagged ? "star.slash" : "star") {
                    Task { await store.flag(item) }
                }
                PillButton(title: "Delete", icon: "trash") { Task { await store.delete(item); dismiss() } }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction).accessibilityLabel("Close")
            }
            .padding(.horizontal, 24).frame(height: 58)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(item.email.title).font(Look.display(26)).foregroundStyle(Look.ink).textSelection(.enabled)
                    HStack(spacing: 12) {
                        Avatar(address: item.email.sender, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.email.sender.display).font(.system(size: 14, weight: .semibold))
                            Text(item.email.sender.email).font(.caption).foregroundStyle(Look.muted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(When.short(item.email.date)).font(.caption).foregroundStyle(Look.muted)
                            HStack(spacing: 5) { AccountDot(account: item.account, size: 6); Text(item.account.label) }
                                .font(.caption).foregroundStyle(Look.muted)
                        }
                    }
                    if let to = item.email.to, !to.isEmpty {
                        Text("To " + to.map(\.display).joined(separator: ", ")).font(.caption).foregroundStyle(Look.muted)
                    }
                    if item.email.hasAttachment == true {
                        Label("Has attachments. Open them in Fastmail for now.", systemImage: "paperclip").font(.callout).foregroundStyle(Look.muted)
                    }
                    if let body = text {
                        Text(body).font(.system(size: 14.5)).lineSpacing(4).foregroundStyle(Look.ink).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    if item.email.isBulk {
                        Label("This is a mailing list. You can unsubscribe from the link in the email.", systemImage: "newspaper")
                            .font(.caption).foregroundStyle(Look.muted)
                    }
                }
                .padding(.horizontal, 40).padding(.vertical, 28)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.white)
        .task {
            text = await store.body(item)
            await store.markRead(item)
        }
    }
}
