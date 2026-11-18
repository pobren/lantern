// Lantern: a clean, fast, native mail app for Mail App and Fastmail, built on JMAP. One app for Mac, iPhone and iPad.

import SwiftUI

@main
struct LanternApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 580)
                #endif
                .tint(Look.accent)
        }
        #if os(macOS)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New message") { NotificationCenter.default.post(name: .lanternCompose, object: nil) }
                    .keyboardShortcut("n")
            }
            CommandMenu("Mailbox") {
                Button("Check for new mail") { Task { await store.refresh() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift, .option])
            }
        }

        Settings {
            SettingsView().environmentObject(store)
        }
        #endif
    }
}

extension Notification.Name {
    static let lanternCompose = Notification.Name("lanternCompose")
}
