// The Mac menu bar: a Message menu with the same actions and shortcuts as the toolbar above an email, the way
// Apple Mail does it, and a Help menu that opens the help pages on jmapconnect.app.

import SwiftUI

/// What the open email can do, handed up to the menu bar by the reading pane that has focus.
struct MessageActions {
    var reply: () -> Void
    var replyAll: () -> Void
    var forward: () -> Void
    var archive: () -> Void
    var delete: () -> Void
    var spam: () -> Void
    var toggleUnread: () -> Void
    var toggleStar: () -> Void
    var editDraft: (() -> Void)?
    var inSpam: Bool
    var unread: Bool
    var starred: Bool
    var mute: (() -> Void)? = nil
    var muted = false
    var print: (() -> Void)? = nil
}

private struct MessageActionsKey: FocusedValueKey { typealias Value = MessageActions }
private struct ComposingKey: FocusedValueKey { typealias Value = Bool }

extension FocusedValues {
    var messageActions: MessageActions? {
        get { self[MessageActionsKey.self] }
        set { self[MessageActionsKey.self] = newValue }
    }
    /// True while an email is being written in this window, so the Message menu leaves the open email alone.
    var composing: Bool? {
        get { self[ComposingKey.self] }
        set { self[ComposingKey.self] = newValue }
    }
}

#if os(macOS)
struct MessageCommands: Commands {
    @FocusedValue(\.messageActions) private var actions
    @FocusedValue(\.composing) private var composing

    private var a: MessageActions? { composing == true ? nil : actions }

    var body: some Commands {
        CommandMenu("Message") {
            Group {
            Button("Reply") { a?.reply() }.keyboardShortcut("r", modifiers: .command)
            Button("Reply all") { a?.replyAll() }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Forward") { a?.forward() }.keyboardShortcut("f", modifiers: [.command, .shift])
            if let edit = a?.editDraft {
                Button("Edit draft") { edit() }.keyboardShortcut("e", modifiers: .command)
            }
            Divider()
            Button("Archive") { a?.archive() }.keyboardShortcut("a", modifiers: [.command, .control])
            Button("Delete") { a?.delete() }.keyboardShortcut(.delete, modifiers: .command)
            Button(a?.inSpam == true ? "Not spam" : "Mark as spam") { a?.spam() }.keyboardShortcut("j", modifiers: [.command, .shift])
            Divider()
            Button(a?.unread == true ? "Mark as read" : "Mark as unread") { a?.toggleUnread() }.keyboardShortcut("u", modifiers: [.command, .shift])
            Button(a?.starred == true ? "Remove star" : "Star") { a?.toggleStar() }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button(a?.muted == true ? "Unmute conversation" : "Mute conversation") { a?.mute?() }.keyboardShortcut("m", modifiers: [.command, .shift])
            }
            .disabled(a == nil)
        }
        // File > Print prints the open email.
        CommandGroup(replacing: .printItem) {
            Button("Print…") { a?.print?() }.keyboardShortcut("p", modifiers: .command).disabled(a?.print == nil)
        }
    }
}

struct HelpCommands: Commands {
    private func openURL(_ url: URL) { NSWorkspace.shared.open(url) }

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("JMAP Connect Help") { openURL(URL(string: "https://jmapconnect.app/help/")!) }
                .keyboardShortcut("?", modifiers: .command)
            Button("Setting up with Fastmail") { openURL(URL(string: "https://jmapconnect.app/setup/")!) }
            Divider()
            Button("Report a problem") { openURL(Community.new(.bug)) }
            Button("Suggest an idea") { openURL(Community.new(.idea)) }
            Button("Ask the community") { openURL(Community.home) }
            Divider()
            Button("Contact") { openURL(URL(string: "https://paulobrien.dev/contact/")!) }
            Button("Privacy") { openURL(URL(string: "https://jmapconnect.app/privacy/")!) }
        }
    }
}
#endif
