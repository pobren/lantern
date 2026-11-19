// The Watch complication: the unread count across your inboxes, on any watch face.
// It asks Fastmail itself every 15 minutes or so, and the Watch app asks it to refresh after each change.

import SwiftUI
import WidgetKit

struct UnreadEntry: TimelineEntry {
    let date: Date
    let unread: Int?
}

struct UnreadProvider: TimelineProvider {
    func placeholder(in context: Context) -> UnreadEntry { UnreadEntry(date: Date(), unread: 3) }

    func getSnapshot(in context: Context, completion: @escaping (UnreadEntry) -> Void) {
        if context.isPreview { completion(UnreadEntry(date: Date(), unread: 3)); return }
        Task { completion(UnreadEntry(date: Date(), unread: await Self.count())) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UnreadEntry>) -> Void) {
        Task {
            let entry = UnreadEntry(date: Date(), unread: await Self.count())
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }

    static func count() async -> Int? {
        let accounts = WatchAccounts.all
        if accounts.isEmpty { return WatchAccounts.sample ? WatchSample.emails().filter(\.unread).count : nil }
        var total = 0
        var any = false
        for a in accounts {
            guard let c = WatchJMAP(a), let n = try? await c.unread() else { continue }
            total += n
            any = true
        }
        return any ? total : nil
    }
}

struct UnreadView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UnreadEntry

    private var number: String { entry.unread.map { $0 > 999 ? "999+" : String($0) } ?? "–" }

    var body: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label("JMAP Connect", systemImage: "envelope.fill").font(.caption2).foregroundStyle(.secondary)
                Text(entry.unread == 0 ? "All read" : "\(number) unread").font(.headline)
                Text("Inbox").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Label(entry.unread == 0 ? "Inbox all read" : "\(number) unread", systemImage: "envelope")
        case .accessoryCorner:
            Image(systemName: "envelope.fill").font(.title3)
                .widgetLabel { Text(entry.unread == 0 ? "All read" : "\(number) unread") }
        default:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "envelope.fill").font(.caption2)
                    Text(number).font(.system(.title3, design: .rounded).weight(.semibold)).minimumScaleFactor(0.5)
                }
            }
        }
    }
}

@main
struct UnreadWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "unread", provider: UnreadProvider()) { entry in
            UnreadView(entry: entry).containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Unread mail")
        .description("How many emails in your inboxes are unread.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}
