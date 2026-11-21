// Undo send (Paul, 20 Nov 2026), after Fastmail's own: for a few seconds after you press Send, an Undo button calls
// the email back and opens it again, just as you wrote it.
//
// The mail server holds the email (the same hold as Send later, RFC 4865 through JMAP), so it still goes on time if
// the app is closed straight after sending, and Undo really does stop it. Servers that can't hold mail send at once.

import SwiftUI

/// What the server made when an email was sent: the email, the submission that sends it, and how long it's held.
struct SentEmail {
    let emailId: String
    let submissionId: String
    let heldUntil: Date?
    let filedIn: String
}

@MainActor
final class UndoSend: ObservableObject {
    static let shared = UndoSend()
    static let key = "undoSendSeconds"
    static let choices = [0, 5, 10, 20, 30]

    /// Seconds to hold each email for, from Settings. Ten unless changed.
    static var seconds: Int {
        UserDefaults.standard.object(forKey: key) == nil ? 10 : UserDefaults.standard.integer(forKey: key)
    }

    struct Pending: Identifiable {
        let id = UUID()
        let sent: SentEmail
        let account: Account
        let draft: ComposeDraft
        let until: Date
    }

    @Published var pending: Pending?
    @Published var working = false
}

extension Store {
    func offerUndo(_ sent: SentEmail, account: Account, draft: ComposeDraft) {
        guard let until = sent.heldUntil else { return }
        UndoSend.shared.pending = UndoSend.Pending(sent: sent, account: account, draft: draft, until: until)
    }

    /// Calls the email back: the send is cancelled and the email goes back to Drafts. Returns the draft to open again,
    /// or nil if it was too late (and says so).
    func undoSend(_ p: UndoSend.Pending) async -> ComposeDraft? {
        guard let s = state(for: p.account), let drafts = s.box("drafts") else { return nil }
        UndoSend.shared.working = true
        defer { UndoSend.shared.working = false; UndoSend.shared.pending = nil }
        do {
            try await s.client.cancelScheduled(p.sent.emailId, waiting: Waiting(submissionId: p.sent.submissionId, sendAt: p.until),
                                               scheduled: p.sent.filedIn, drafts: drafts.id)
        } catch {
            problem = "Too late to undo: the email has gone."
            return nil
        }
        await refresh()
        var d = p.draft
        d.draftId = p.sent.emailId
        return d
    }
}

/// The bar along the bottom of the window after sending: "Sending…" with Undo, until the server lets it go.
struct UndoSendBar: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var undo = UndoSend.shared
    let reopen: (ComposeDraft) -> Void

    var body: some View {
        if let p = undo.pending {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(p.until.timeIntervalSince(context.date).rounded(.up)))
                HStack(spacing: 12) {
                    Label(left > 0 ? "Sending in \(left)s" : "Sent", systemImage: left > 0 ? "paperplane" : "checkmark.circle")
                        .monospacedDigit()
                    if left > 0 {
                        Button {
                            Task { if let d = await store.undoSend(p) { reopen(d) } }
                        } label: {
                            if undo.working { ProgressView().controlSize(.small) } else { Label("Undo", systemImage: "arrow.uturn.backward") }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(undo.working)
                        .keyboardShortcut("z", modifiers: .command)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .padding(.bottom, 18)
                .task(id: p.id) {
                    // Gone: the bar stays a moment saying "Sent", then goes.
                    let wait = max(0, p.until.timeIntervalSinceNow) + 1.5
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    if undo.pending?.id == p.id && !undo.working { undo.pending = nil }
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Settings: how long Undo send waits.
struct UndoSendSetting: View {
    @AppStorage(UndoSend.key) private var seconds = 10

    var body: some View {
        Picker(selection: $seconds) {
            ForEach(UndoSend.choices, id: \.self) { n in Text(n == 0 ? "Off" : "\(n) seconds").tag(n) }
        } label: {
            Label("Undo send", systemImage: "arrow.uturn.backward.circle")
        }
    }
}
