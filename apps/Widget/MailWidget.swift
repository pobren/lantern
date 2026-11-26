// Home Screen and Lock Screen widgets (Paul, 21 Nov 2026): the unread count, and the latest emails in your inbox.
// They show what the app last saw; the app refreshes them each time the inbox changes.

import SwiftUI
import WidgetKit

struct MailEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct MailProvider: TimelineProvider {
    static let sample = WidgetSnapshot(unread: 3, latest: [
        .init(id: "1", account: "", sender: "Maya Chen", subject: "Sketches for the spring launch", date: Date(), unread: true),
        .init(id: "2", account: "", sender: "Fastmail", subject: "Your monthly summary", date: Date().addingTimeInterval(-3600), unread: true),
        .init(id: "3", account: "", sender: "Sam Patel", subject: "Lunch on Thursday?", date: Date().addingTimeInterval(-7200), unread: false),
        .init(id: "4", account: "", sender: "The Times", subject: "Saturday's briefing", date: Date().addingTimeInterval(-9000), unread: false),
    ], saved: Date())

    func placeholder(in context: Context) -> MailEntry { MailEntry(date: Date(), snapshot: Self.sample) }

    func getSnapshot(in context: Context, completion: @escaping (MailEntry) -> Void) {
        completion(MailEntry(date: Date(), snapshot: context.isPreview ? Self.sample : (WidgetStore.read() ?? Self.sample)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MailEntry>) -> Void) {
        let entry = MailEntry(date: Date(), snapshot: WidgetStore.read())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

private let accent = Color(red: 0x2F / 255, green: 0x5B / 255, blue: 0xD3 / 255)

struct MailWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MailEntry

    private var unread: Int { entry.snapshot?.unread ?? 0 }
    private var count: String { unread > 999 ? "999+" : String(unread) }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "envelope.fill").font(.caption)
                    Text(count).font(.headline).minimumScaleFactor(0.6)
                }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label(unread == 0 ? "All read" : "\(count) unread", systemImage: "envelope.fill").font(.headline)
                if let first = entry.snapshot?.latest.first {
                    Text(first.sender).font(.caption).lineLimit(1)
                    Text(first.subject).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Label(unread == 0 ? "Inbox all read" : "\(count) unread", systemImage: "envelope")
        case .systemSmall:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "envelope.fill").foregroundStyle(accent)
                    Spacer()
                }
                Spacer(minLength: 0)
                Text(count).font(.system(size: 40, weight: .bold, design: .rounded)).minimumScaleFactor(0.5)
                Text(unread == 1 ? "unread email" : "unread emails").font(.caption).foregroundStyle(.secondary)
                if let first = entry.snapshot?.latest.first {
                    Text(first.sender).font(.caption2.weight(.semibold)).lineLimit(1)
                }
            }
        default:
            let rows = Array((entry.snapshot?.latest ?? []).prefix(family == .systemLarge ? 8 : 3))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Inbox", systemImage: "envelope.fill").font(.headline).foregroundStyle(accent)
                    Spacer()
                    Text(unread == 0 ? "All read" : "\(count) unread").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                if rows.isEmpty {
                    Spacer()
                    Text("Open JMAP Connect to fill this in.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(rows) { m in
                        HStack(alignment: .top, spacing: 6) {
                            Circle().fill(m.unread ? accent : .clear).frame(width: 6, height: 6).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 0) {
                                HStack {
                                    Text(m.sender).font(.caption.weight(m.unread ? .bold : .semibold)).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(m.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(m.subject).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct MailWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MailWidget", provider: MailProvider()) { entry in
            MailWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Inbox")
        .description("Your unread count and latest emails.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct MailWidgets: WidgetBundle {
    var body: some Widget { MailWidget() }
}
