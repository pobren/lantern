// Private AI (Paul, 21 Nov 2026): summarise an email, catch up on what's new, and draft a reply, using Apple
// Intelligence on the device itself. No email goes to any server, ours or anyone else's, and it costs nothing to run.
// Off until turned on in Settings, and only offered on devices with Apple Intelligence (2026 software, recent chips).

import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

enum PrivateAI {
    static let key = "privateAI"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Whether this device can run it at all (Apple Intelligence on, model downloaded).
    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    /// Why it can't run here, for Settings.
    static var unavailableReason: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return ""
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to use this."
            case .unavailable(.modelNotReady): return "Apple Intelligence is still getting ready on this device. Try again later."
            case .unavailable(.deviceNotEligible): return "This device doesn't support Apple Intelligence."
            default: return "Apple Intelligence isn't available on this device."
            }
        }
        #endif
        return "Needs Apple Intelligence (macOS 26 or iOS 26 on a recent device)."
    }

    static func ask(_ instructions: String, _ prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let session = LanguageModelSession(instructions: instructions)
            let answer = try await session.respond(to: prompt)
            return answer.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw JMAPError.missing("Apple Intelligence")
    }

    private static let house = "Write in UK English. Be plain and brief. Never use dashes or bullet symbols other than '• '. Don't invent anything that isn't in the email."

    static func summarise(_ e: Email, text: String) async throws -> String {
        try await ask(
            "You summarise emails for the person who received them. " + house,
            "Summarise this email in at most three short sentences. Then, if it asks the reader to do something or mentions a date or deadline, add one line starting 'To do: '.\n\nFrom: \(e.sender.display)\nSubject: \(e.title)\n\n" + String(text.prefix(6000)))
    }

    static func catchUp(_ emails: [Email]) async throws -> String {
        let lines = emails.prefix(25).map { e in "• \(e.sender.display): \(e.title). \(String((e.preview ?? "").prefix(160)))" }
        return try await ask(
            "You give people a quick catch up on their unread email. " + house,
            "Here are my unread emails. In at most eight lines starting with '• ', tell me what matters most first, group newsletters and adverts into one line at the end, and mention anything that needs a reply.\n\n" + lines.joined(separator: "\n"))
    }

    static func draftReply(to e: Email, text: String, me: String) async throws -> String {
        try await ask(
            "You draft short, friendly email replies for \(me.isEmpty ? "the reader" : me) to check and edit before sending. " + house + " Write only the reply's words: no subject line, no signature, no placeholders in brackets.",
            "Draft a reply to this email.\n\nFrom: \(e.sender.display)\nSubject: \(e.title)\n\n" + String(text.prefix(5000)))
    }
}

/// The Summarise and Draft reply buttons above an email, and the summary once it's made.
struct AIEmailTools: View {
    @EnvironmentObject var store: Store
    let email: Email
    let account: Account
    let compose: (ComposeDraft) -> Void
    @State private var summary: String?
    @State private var working: String?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { Task { await summarise() } } label: { Label("Summarise", systemImage: "sparkles") }
                Button { Task { await draft() } } label: { Label("Draft a reply", systemImage: "pencil.and.sparkles") }
                if let working {
                    ProgressView().controlSize(.small)
                    Text(working).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(working != nil)
            if let summary {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Summary, made on this device", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(summary).font(Look.size(14)).textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Look.accent.opacity(0.08)))
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
        }
        .id(email.id)
    }

    private func summarise() async {
        working = "Summarising on this device…"; problem = nil
        defer { working = nil }
        let text = await store.text(email, account: account)
        do { summary = try await PrivateAI.summarise(email, text: text) }
        catch { problem = "Couldn't summarise: \(error.localizedDescription)" }
    }

    private func draft() async {
        working = "Writing a draft on this device…"; problem = nil
        defer { working = nil }
        let text = await store.text(email, account: account)
        do {
            let me = store.state(for: account).flatMap { store.defaultIdentity($0) }?.name ?? ""
            let words = try await PrivateAI.draftReply(to: email, text: text, me: me)
            var d = ComposeDraft.reply(to: email, account: account, all: false, quoting: text, store: store)
            d.text = words + d.text
            compose(d)
        } catch { problem = "Couldn't draft a reply: \(error.localizedDescription)" }
    }
}

/// Catch up: what's new in your unread mail, in a few lines.
struct CatchUpButton: View {
    @EnvironmentObject var store: Store
    @AppStorage(PrivateAI.key) private var on = false
    @State private var showing = false

    var body: some View {
        if on && PrivateAI.available {
            Button { showing = true } label: { Label("Catch up", systemImage: "sparkles") }
                .help("A quick summary of your unread email, made on this device")
                .sheet(isPresented: $showing) { CatchUpView().environmentObject(store) }
        }
    }
}

struct CatchUpView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let text {
                        Text(text).font(Look.size(15)).lineSpacing(4).textSelection(.enabled)
                        Label("Made on this device. Your email didn't leave it.", systemImage: "lock.shield")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let problem {
                        Text(problem).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 10) { ProgressView(); Text("Reading your unread email on this device…").foregroundStyle(.secondary) }
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Catch up")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Label("Done", systemImage: "checkmark") }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
        .task {
            let unread = store.shownAccounts.flatMap { $0.inbox }.filter(\.isUnread).sorted { $0.date > $1.date }
            guard !unread.isEmpty else { text = "You're all caught up. Nothing unread in your inbox."; return }
            do { text = try await PrivateAI.catchUp(unread) }
            catch { problem = "Couldn't make a catch up: \(error.localizedDescription)" }
        }
    }
}

/// Settings: the switch, off until turned on.
struct PrivateAISetting: View {
    @AppStorage(PrivateAI.key) private var on = false

    var body: some View {
        Section {
            Toggle(isOn: $on) { Label("Private AI", systemImage: "sparkles") }
                .disabled(!PrivateAI.available)
        } footer: {
            Text(PrivateAI.available
                 ? "Summarise emails, catch up on what's unread and draft replies, using Apple Intelligence on this device. Your email never leaves it and nothing is sent to us or anyone else."
                 : PrivateAI.unavailableReason)
        }
    }
}
