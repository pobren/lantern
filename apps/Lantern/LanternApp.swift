// Lantern: a calm, native Mac mail app for Fastmail and Mail App, built on JMAP.

import SwiftUI

@main
struct LanternApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 1000, minHeight: 640)
                .tint(Look.accent)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New message") { NotificationCenter.default.post(name: .lanternCompose, object: nil) }
                    .keyboardShortcut("n")
            }
            CommandMenu("Mail") {
                Button("Check for new mail") { Task { await store.refresh() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView().environmentObject(store)
        }
    }
}

extension Notification.Name {
    static let lanternCompose = Notification.Name("lanternCompose")
}
