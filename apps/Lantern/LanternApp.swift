// Lantern: a clean, fast, native mail app for Mail App and Fastmail, built on JMAP. One app for Mac, iPhone and iPad.

import SwiftUI
import UserNotifications
#if os(iOS)
import BackgroundTasks
#endif

@main
struct LanternApp: App {
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var phase
    static let refreshTask = "dev.paulobrien.lantern.refresh"

    init() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            window.frame(minWidth: 900, minHeight: 580)
        }
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

        WindowGroup("Email", for: MessageRef.self) { $ref in
            if let ref {
                MessageWindow(ref: ref)
                    .environmentObject(store)
                    .tint(Look.accent)
                    .frame(minWidth: 520, minHeight: 420)
            }
        }
        .defaultSize(width: 760, height: 820)

        Settings {
            SettingsView().environmentObject(store)
        }
        #else
        WindowGroup {
            window
        }
        .onChange(of: phase) { _, now in
            if now == .background { Self.scheduleRefresh() }
        }
        .backgroundTask(.appRefresh(Self.refreshTask)) {
            Self.scheduleRefresh()
            await store.backgroundCheck()
        }
        #endif
    }

    #if os(iOS)
    /// Asks iOS to wake Lantern to check for mail in about 15 minutes. iOS decides the real time.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif

    private var window: some View {
        RootView()
            .environmentObject(store)
            .tint(Look.accent)
            .task { await Notifier.ask() }
    }
}

extension Notification.Name {
    static let lanternCompose = Notification.Name("lanternCompose")
}
