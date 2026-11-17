// Reading one email: who it's from, the email as its sender laid it out, and what to do with it.

import SwiftUI

struct MessageView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("remoteImages") private var remoteImages = true
    let item: Item
    let onReply: () -> Void
    @State private var html: String?
    @State private var loading = true
    @State private var showImagesOnce = false

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
            header.padding(.horizontal, 40).padding(.top, 24).padding(.bottom, 14)
            if !remoteImages && !showImagesOnce && (html?.contains("http") ?? false) {
                HStack(spacing: 10) {
                    Image(systemName: "photo")
                    Text("Pictures from the web are hidden to protect your privacy.").font(.callout)
                    Spacer()
                    Button { showImagesOnce = true } label: { Label("Show pictures", systemImage: "eye") }
                    Button { remoteImages = true } label: { Label("Always show", systemImage: "checkmark") }
                }
                .foregroundStyle(Look.muted)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Look.ground))
                .padding(.horizontal, 40).padding(.bottom, 10)
            }
            Divider().padding(.horizontal, 40)
            Group {
                if let html {
                    EmailWebView(html: html, remoteImages: remoteImages || showImagesOnce)
                } else if loading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        Text(item.email.preview ?? "").font(.system(size: 14.5)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 32).padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.white)
        .task {
            html = await store.page(item)
            loading = false
            await store.markRead(item)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.email.title).font(Look.display(24)).foregroundStyle(Look.ink).textSelection(.enabled).lineLimit(3)
            HStack(spacing: 12) {
                Avatar(address: item.email.sender, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.email.sender.display).font(.system(size: 14, weight: .semibold))
                    Text(item.email.sender.email).font(.caption).foregroundStyle(Look.muted)
                    if let to = item.email.to, !to.isEmpty {
                        Text("To " + to.map(\.display).joined(separator: ", ")).font(.caption).foregroundStyle(Look.muted).lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(When.short(item.email.date)).font(.caption).foregroundStyle(Look.muted)
                    HStack(spacing: 5) { AccountDot(account: item.account, size: 6); Text(item.account.label) }
                        .font(.caption).foregroundStyle(Look.muted)
                    if item.email.hasAttachment == true {
                        Label("Attachments", systemImage: "paperclip").font(.caption).foregroundStyle(Look.muted)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
