// The calendar's screens: a month and your calendars in the middle column, the day or week on the right, and an
// event's details with Accept, Maybe and Decline when you're a guest.

import SwiftUI
import AuthenticationServices

// MARK: Middle column: month, calendars, the chosen day

struct CalendarSide: View {
    @EnvironmentObject var store: Store
    @ObservedObject var model: CalendarModel
    /// On iPhone, moves on to the day or week after a day is tapped.
    var openDay: () -> Void = {}
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var turningOn: String?
    @State private var chosen: CalEvent?
    @State private var drafting: DraftBox?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        List {
            Section {
                MonthGrid(model: model, pick: { d in model.date = d; openDay() })
                    .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            }
            ForEach(model.needsApproval, id: \.self) { id in
                if let s = store.state(id: id) {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Show your Fastmail calendar").font(.headline)
                            Text("Fastmail asks you to approve calendar access once. Your mail stays signed in.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button {
                                turningOn = id
                                Task { await model.turnOn(s, using: webAuth, store: store); turningOn = nil }
                            } label: {
                                Label(turningOn == id ? "Waiting for Fastmail" : "Turn on calendar", systemImage: "calendar.badge.plus")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(turningOn != nil)
                        }
                        .padding(.vertical, 4)
                    } header: { Text(s.account.label) }
                }
            }
            if let p = model.problem {
                Section { Label(p, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary) }
            }
            let day = model.events(in: DateInterval(start: Calendar.current.startOfDay(for: model.date), duration: 86_400))
            Section {
                if day.isEmpty {
                    Text("Nothing on").foregroundStyle(.secondary)
                } else {
                    ForEach(day) { e in
                        Button { chosen = e } label: { AgendaRow(event: e, model: model) }
                            .buttonStyle(.plain)
                    }
                }
            } header: { Text(CalText.longDay.string(from: model.date)) }
        }
        .navigationTitle("Calendar")
        .sheet(item: $chosen) { e in EventDetail(event: e, model: model).environmentObject(store) }
        .sheet(item: $drafting) { box in EventEditor(model: model, draft: box.draft).environmentObject(store) }
        #if os(iOS)
        // iPhone opens here first, so New event and the calendar switches are here too (the day and week have them on iPad and Mac).
        .toolbar {
            if sizeClass == .compact {
                ToolbarItemGroup(placement: .primaryAction) {
                    CalendarsMenu(model: model)
                    if !model.writableCalendars.isEmpty {
                        Button { drafting = DraftBox(draft: model.newDraft()) } label: { Label("New event", systemImage: "plus") }
                    }
                }
            }
        }
        #endif
        .refreshable { await model.refresh(store) }
        .task { await model.start(store) }
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 260, ideal: 290, max: 360)
        #endif
    }
}

private struct AgendaRow: View {
    let event: CalEvent
    @ObservedObject var model: CalendarModel
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(model.colour(event.calendar)).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.body.weight(.medium)).lineLimit(2)
                Text(event.timeText).font(.caption).foregroundStyle(.secondary)
                if !event.location.isEmpty && event.joinLink?.absoluteString != event.location {
                    Text(event.location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// A month of days, Monday first, with a dot on days that have something on.
struct MonthGrid: View {
    @ObservedObject var model: CalendarModel
    let pick: (Date) -> Void
    @State private var month = Date()

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.timeZone = .current
        return c
    }

    var body: some View {
        let start = cal.dateInterval(of: .month, for: month)?.start ?? month
        let gridStart = cal.dateInterval(of: .weekOfYear, for: start)?.start ?? start
        let days = (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
        let busy = Set(model.events(in: DateInterval(start: gridStart, end: days.last!.addingTimeInterval(86_400)))
            .flatMap { e -> [Date] in
                var out: [Date] = []
                var d = cal.startOfDay(for: e.start)
                let last = e.allDay ? e.end.addingTimeInterval(-1) : e.end
                while d <= last && out.count < 42 { out.append(d); d = cal.date(byAdding: .day, value: 1, to: d)! }
                return out
            })
        VStack(spacing: 6) {
            HStack {
                Text(CalText.month.string(from: month)).font(.headline)
                Spacer()
                Button { month = cal.date(byAdding: .month, value: -1, to: month) ?? month } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).accessibilityLabel("Previous month")
                Button { month = cal.date(byAdding: .month, value: 1, to: month) ?? month } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).accessibilityLabel("Next month")
            }
            let cols = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(0..<7, id: \.self) { i in
                    Text(CalText.weekday.string(from: days[i]).prefix(2)).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(days, id: \.self) { d in
                    let inMonth = cal.isDate(d, equalTo: month, toGranularity: .month)
                    let chosen = cal.isDate(d, inSameDayAs: model.date)
                    let today = cal.isDateInToday(d)
                    Button { pick(d) } label: {
                        VStack(spacing: 2) {
                            Text(CalText.dayNumber.string(from: d))
                                .font(.callout.weight(today ? .bold : .regular))
                                .foregroundStyle(chosen ? Color.white : today ? Look.accent : inMonth ? Color.primary : Color.secondary.opacity(0.6))
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(chosen ? Look.accent : .clear))
                            Circle().fill(busy.contains(d) ? Color.secondary : .clear).frame(width: 4, height: 4)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(CalText.longDay.string(from: d))
                }
            }
        }
        .onAppear { month = model.date }
        .onChange(of: model.date) { _, d in if !cal.isDate(d, equalTo: month, toGranularity: .month) { month = d } }
    }
}

// MARK: Right: the day or the week

struct CalendarGrid: View {
    @EnvironmentObject var store: Store
    @ObservedObject var model: CalendarModel
    @State private var chosen: CalEvent?
    @State private var drafting: DraftBox?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    private let hourHeight: CGFloat = 52
    private var gutter: CGFloat { compact ? 40 : 46 }

    var body: some View {
        let days = model.days
        let events = model.events(in: model.range)
        VStack(spacing: 0) {
            header.fixedSize(horizontal: false, vertical: true)
            Divider()
            if model.mode == .month {
                MonthView(model: model, events: events, open: { chosen = $0 })
            } else {
                dayHeadings(days).fixedSize(horizontal: false, vertical: true)
                allDayRow(days, events.filter(\.allDay)).fixedSize(horizontal: false, vertical: true)
                Divider()
                ScrollViewReader { reader in
                    ScrollView {
                        timed(days, events.filter { !$0.allDay })
                    }
                    .frame(maxHeight: .infinity)
                    // Opens on the working day (8am, or earlier if something starts before then).
                    .onAppear { scroll(reader, events) }
                    .onChange(of: model.range) { _, _ in scroll(reader, model.events(in: model.range)) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Look.paper)
        .sheet(item: $chosen) { e in EventDetail(event: e, model: model).environmentObject(store) }
        .sheet(item: $drafting) { box in EventEditor(model: model, draft: box.draft).environmentObject(store) }
        .task(id: model.range) { await model.ensure(model.range, store: store) }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if compact {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.date = Date() } label: { Label("Today", systemImage: "calendar.circle") }
                    CalendarsMenu(model: model)
                    if !model.writableCalendars.isEmpty {
                        Button { drafting = DraftBox(draft: model.newDraft()) } label: { Label("New event", systemImage: "plus") }
                    }
                }
            }
        }
        #endif
        .navigationTitle(title)
    }

    private var title: String {
        switch model.mode {
        case .day: return CalText.longDay.string(from: model.date)
        case .month: return CalText.month.string(from: model.date)
        case .week: return CalText.month.string(from: model.days.first ?? model.date)
        }
    }

    private func scroll(_ reader: ScrollViewProxy, _ events: [CalEvent]) {
        let hour = max(0, firstHour(events) - 1)
        DispatchQueue.main.async { reader.scrollTo("hour-\(hour)", anchor: .top) }
    }

    private func firstHour(_ events: [CalEvent]) -> Int {
        let cal = Calendar.current
        let timed = events.filter { !$0.allDay }.map { cal.component(.hour, from: $0.start) }
        return min(8, timed.min() ?? 8)
    }

    private var compact: Bool {
        #if os(iOS)
        return sizeClass == .compact
        #else
        return false
        #endif
    }

    private var modePicker: some View {
        Picker("Show", selection: $model.mode) {
            Text("Day").tag(CalendarModel.Mode.day)
            Text("Week").tag(CalendarModel.Mode.week)
            Text("Month").tag(CalendarModel.Mode.month)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var back: some View {
        Button { model.move(-1) } label: { Image(systemName: "chevron.left").frame(minWidth: 22, minHeight: 22) }
            .accessibilityLabel(model.mode == .day ? "Previous day" : model.mode == .week ? "Previous week" : "Previous month")
            .keyboardShortcut(.leftArrow, modifiers: .command)
    }
    private var forward: some View {
        Button { model.move(1) } label: { Image(systemName: "chevron.right").frame(minWidth: 22, minHeight: 22) }
            .accessibilityLabel(model.mode == .day ? "Next day" : model.mode == .week ? "Next week" : "Next month")
            .keyboardShortcut(.rightArrow, modifiers: .command)
    }

    @ViewBuilder private var header: some View {
        if compact {
            // iPhone: the arrows either side of Day, Week and Month; New event, Calendars and Today in the bar above.
            HStack(spacing: 8) {
                back.buttonStyle(.borderless)
                modePicker
                forward.buttonStyle(.borderless)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        } else {
            HStack(spacing: 10) {
                #if os(macOS)
                Text(title).font(.title3.weight(.semibold)).lineLimit(1)
                #endif
                Spacer(minLength: 0)
                if !model.writableCalendars.isEmpty {
                    Button { drafting = DraftBox(draft: model.newDraft()) } label: { Label("New event", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                        .help("New event")
                }
                CalendarsMenu(model: model)
                Button { model.date = Date() } label: { Label("Today", systemImage: "calendar.circle") }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.bordered)
                back.buttonStyle(.bordered)
                forward.buttonStyle(.bordered)
                modePicker.fixedSize()
                if model.loading { ProgressView().controlSize(.small) }
                else {
                    Button { Task { await model.refresh(store) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).accessibilityLabel("Check for changes")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private func dayHeadings(_ days: [Date]) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter)
            ForEach(days, id: \.self) { d in
                let today = Calendar.current.isDateInToday(d)
                Button { model.date = d; model.mode = .day } label: {
                    // On iPhone the weekday sits above the number, so seven days fit across.
                    let stack = compact ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 4))
                    stack {
                        Text(compact ? String(CalText.weekday.string(from: d).prefix(1)) : CalText.weekday.string(from: d))
                            .foregroundStyle(.secondary)
                        Text(CalText.dayNumber.string(from: d))
                            .fontWeight(today ? .bold : .regular)
                            .foregroundStyle(today ? Color.white : Color.primary)
                            .padding(.horizontal, today ? 6 : 0).padding(.vertical, today ? 1 : 0)
                            .background(Capsule().fill(today ? Look.accent : .clear))
                    }
                    .font(.callout)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func allDayRow(_ days: [Date], _ events: [CalEvent]) -> some View {
        let cal = Calendar.current
        let perDay = days.map { d in events.filter { e in e.start < d.addingTimeInterval(86_400) && e.end > d } }
        return Group {
            if perDay.contains(where: { !$0.isEmpty }) {
                HStack(alignment: .top, spacing: 0) {
                    Text("All day").font(.caption2).foregroundStyle(.secondary).frame(width: gutter)
                    ForEach(days.indices, id: \.self) { i in
                        VStack(spacing: 2) {
                            ForEach(perDay[i]) { e in
                                Button { chosen = e } label: {
                                    Text(e.title).font(.caption.weight(.medium)).lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(RoundedRectangle(cornerRadius: 4).fill(model.colour(e.calendar).opacity(0.25)))
                                        .foregroundStyle(Color.primary)
                                }
                                .buttonStyle(.plain)
                                .help(e.title)
                            }
                        }
                        .padding(.horizontal, 1)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .id(cal.startOfDay(for: days[i]))
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func timed(_ days: [Date], _ events: [CalEvent]) -> some View {
        // The hours are laid out for real (so the list can scroll to 8am); events sit on top of them.
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { h in
                HStack(alignment: .top, spacing: 0) {
                    Text(h == 0 ? "" : String(format: "%02d:00", h))
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: gutter - 6, alignment: .trailing)
                        .offset(y: -7)
                    Rectangle().fill(Look.line.opacity(0.6)).frame(height: 0.5).padding(.leading, 6)
                }
                .frame(height: hourHeight, alignment: .top)
                .id("hour-\(h)")
            }
        }
        .padding(.top, 8)
        .overlay(alignment: .topLeading) {
            GeometryReader { geo in
                let width = max(0, (geo.size.width - gutter) / CGFloat(days.count))
                ZStack(alignment: .topLeading) {
                    Color.clear
                    // Lines between days.
                    ForEach(1..<max(1, days.count), id: \.self) { i in
                        Rectangle().fill(Look.line.opacity(0.4)).frame(width: 0.5, height: hourHeight * 24)
                            .offset(x: gutter + CGFloat(i) * width)
                    }
                    ForEach(days.indices, id: \.self) { i in
                        let placed = DayLayout.place(events, on: days[i])
                        ForEach(placed, id: \.event.id) { p in
                            let top = CGFloat(p.startMinutes) / 60 * hourHeight
                            let height = max(20, CGFloat(p.endMinutes - p.startMinutes) / 60 * hourHeight - 2)
                            let colWidth = (width - 4) / CGFloat(p.columns)
                            Button { chosen = p.event } label: {
                                EventBlock(event: p.event, colour: model.colour(p.event.calendar), compact: height < 36 || colWidth < 60)
                                    .frame(width: max(0, colWidth - 2), height: height, alignment: .topLeading)
                            }
                            .buttonStyle(.plain)
                            .help("\(p.event.title), \(p.event.timeText)")
                            .offset(x: gutter + CGFloat(i) * width + 2 + CGFloat(p.column) * colWidth, y: top + 1)
                        }
                        if Calendar.current.isDateInToday(days[i]) {
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                let now = Calendar.current.dateComponents([.hour, .minute], from: context.date)
                                let y = (CGFloat(now.hour ?? 0) + CGFloat(now.minute ?? 0) / 60) * hourHeight
                                HStack(spacing: 0) {
                                    Circle().fill(Color.red).frame(width: 7, height: 7)
                                    Rectangle().fill(Color.red).frame(height: 1.5)
                                }
                                .frame(width: width + 4)
                                .offset(x: gutter + CGFloat(i) * width - 3, y: y - 3.5)
                            }
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
    }
}

/// A month at a glance: six weeks, each day with as many events as fit and "n more" after.
private struct MonthView: View {
    @ObservedObject var model: CalendarModel
    let events: [CalEvent]
    let open: (CalEvent) -> Void

    var body: some View {
        let days = model.days
        let cal = Calendar.current
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(CalText.weekday.string(from: days[i])).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            GeometryReader { geo in
                let rowHeight = geo.size.height / 6
                let fits = max(0, Int((rowHeight - 26) / 17))
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { col in
                                let d = days[row * 7 + col]
                                let next = cal.date(byAdding: .day, value: 1, to: d) ?? d
                                let on = events.filter { $0.start < next && ($0.end > d || $0.start >= d) }
                                cell(d, on, fits: fits)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .overlay(alignment: .trailing) { Rectangle().fill(Look.line.opacity(0.4)).frame(width: 0.5) }
                            }
                        }
                        .frame(height: rowHeight)
                        .overlay(alignment: .bottom) { Rectangle().fill(Look.line.opacity(0.5)).frame(height: 0.5) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func cell(_ d: Date, _ on: [CalEvent], fits: Int) -> some View {
        let cal = Calendar.current
        let inMonth = cal.isDate(d, equalTo: model.date, toGranularity: .month)
        let today = cal.isDateInToday(d)
        VStack(alignment: .leading, spacing: 1) {
            Button { model.date = d; model.mode = .day } label: {
                Text(CalText.dayNumber.string(from: d))
                    .font(.callout.weight(today ? .bold : .regular))
                    .foregroundStyle(today ? Color.white : inMonth ? Color.primary : Color.secondary.opacity(0.6))
                    .frame(minWidth: 24, minHeight: 22)
                    .background(Circle().fill(today ? Look.accent : .clear))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(CalText.longDay.string(from: d))
            let shown = on.count > fits ? Array(on.prefix(max(0, fits - 1))) : on
            ForEach(shown) { e in
                Button { open(e) } label: {
                    HStack(spacing: 4) {
                        if e.allDay {
                            Text(e.title).lineLimit(1)
                                .padding(.horizontal, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 3).fill(model.colour(e.calendar).opacity(0.25)))
                        } else {
                            Circle().fill(model.colour(e.calendar)).frame(width: 6, height: 6)
                            Text(CalText.time.string(from: e.start)).foregroundStyle(.secondary)
                            Text(e.title).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .font(.caption)
                    .frame(height: 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(e.title), \(e.timeText)")
            }
            if on.count > shown.count {
                Button { model.date = d; model.mode = .day } label: {
                    Text("\(on.count - shown.count) more").font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .opacity(inMonth ? 1 : 0.55)
    }
}

private struct EventBlock: View {
    let event: CalEvent
    let colour: Color
    let compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(event.title).font(.caption.weight(.semibold)).lineLimit(compact ? 1 : 3)
            if !compact {
                Text(CalText.time.string(from: event.start)).font(.caption2).foregroundStyle(.secondary)
                if !event.location.isEmpty && event.joinLink == nil {
                    Text(event.location).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 5).padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 5).fill(colour.opacity(event.tentative ? 0.12 : 0.22))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(colour).frame(width: 3).padding(.vertical, 2)
        }
        .foregroundStyle(Color.primary)
        .clipped()
    }
}

/// Side by side placing of events that overlap on one day.
enum DayLayout {
    struct Placed {
        let event: CalEvent
        let startMinutes: Int
        let endMinutes: Int
        var column: Int
        var columns: Int
    }

    static func place(_ events: [CalEvent], on day: Date) -> [Placed] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        let mine = events.filter { $0.start < end && $0.end > start || ($0.start >= start && $0.start < end) }
        var items: [Placed] = mine.map { e in
            let s = max(0, Int(max(e.start, start).timeIntervalSince(start) / 60))
            let f = min(24 * 60, Int(min(max(e.end, e.start.addingTimeInterval(30 * 60)), end).timeIntervalSince(start) / 60))
            return Placed(event: e, startMinutes: s, endMinutes: max(s + 15, f), column: 0, columns: 1)
        }.sorted { ($0.startMinutes, -$0.endMinutes) < ($1.startMinutes, -$1.endMinutes) }
        // Groups of events that touch each other share the width.
        var group: [Int] = []
        var groupEnd = -1
        var columnsEnd: [Int] = []
        func close() {
            let n = max(1, columnsEnd.count)
            for i in group { items[i].columns = n }
            group = []; columnsEnd = []
        }
        for i in items.indices {
            if items[i].startMinutes >= groupEnd { close() }
            if let c = columnsEnd.firstIndex(where: { $0 <= items[i].startMinutes }) {
                items[i].column = c
                columnsEnd[c] = items[i].endMinutes
            } else {
                items[i].column = columnsEnd.count
                columnsEnd.append(items[i].endMinutes)
            }
            group.append(i)
            groupEnd = max(groupEnd, items[i].endMinutes)
        }
        close()
        return items
    }
}

// MARK: An event

struct EventDetail: View {
    @EnvironmentObject var store: Store
    let event: CalEvent
    @ObservedObject var model: CalendarModel
    @Environment(\.dismiss) private var dismiss
    @State private var working: String?
    @State private var problem: String?
    @State private var answered: String?
    @State private var editing: DraftBox?
    @State private var confirmDelete = false

    private var account: AccountState? { store.state(id: event.calendar.accountId) }
    private var me: CalPerson? {
        guard let s = account else { return nil }
        let mine = model.myAddresses(s)
        return event.attendees.first { mine.contains($0.email.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(event.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Text(CalText.longDay.string(from: event.start)).foregroundStyle(.secondary)
                        Text(event.timeText + (event.repeats ? ", repeats" : "")).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    HStack(spacing: 8) {
                        Circle().fill(model.colour(event.calendar)).frame(width: 10, height: 10)
                        Text(event.calendar.name)
                    }
                    if let link = event.joinLink {
                        Link(destination: link) { Label("Join the call", systemImage: "video.fill") }
                    }
                    if !event.location.isEmpty && event.location != event.joinLink?.absoluteString {
                        Label(event.location, systemImage: "mappin.and.ellipse").textSelection(.enabled)
                    }
                }
                if let me {
                    Section {
                        AnswerButtons(current: answered ?? me.status, working: working) { status in
                            Task { await answer(status) }
                        }
                        if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
                    } header: { Text("Going?") }
                }
                if event.organizer != nil || !event.attendees.isEmpty {
                    Section("People") {
                        if let o = event.organizer {
                            PersonRow(person: o, note: "Organiser")
                        }
                        ForEach(event.attendees.filter { $0.email.lowercased() != event.organizer?.email.lowercased() }) { p in
                            PersonRow(person: p, note: nil)
                        }
                    }
                }
                if !event.notes.isEmpty {
                    Section("Notes") { Text(event.notes).textSelection(.enabled) }
                }
                if me == nil, let problem {
                    Section { Text(problem).font(.callout).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Event")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Label("Done", systemImage: "checkmark") }
                }
                if model.canEdit(event) {
                    ToolbarItem(placement: .primaryAction) {
                        Button { editing = DraftBox(draft: model.draft(editing: event)) } label: { Label("Edit", systemImage: "pencil") }
                    }
                    ToolbarItem(placement: .destructiveAction) {
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .confirmationDialog(event.repeats ? "Delete this repeating event?" : "Delete this event?", isPresented: $confirmDelete, titleVisibility: .visible) {
                if event.repeats {
                    Button("Delete this one only", role: .destructive) { Task { await remove(onlyThis: true) } }
                    Button("Delete all repeats", role: .destructive) { Task { await remove(onlyThis: false) } }
                } else {
                    Button("Delete", role: .destructive) { Task { await remove(onlyThis: false) } }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $editing) { box in EventEditor(model: model, draft: box.draft, saved: { dismiss() }).environmentObject(store) }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 440)
        #endif
    }

    private func remove(onlyThis: Bool) async {
        do {
            try await model.delete(event, onlyThis: onlyThis, store: store)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func answer(_ status: String) async {
        guard let s = account, let v = model.component(for: event) else { return }
        working = status; problem = nil
        defer { working = nil }
        do {
            try await model.respond(v, status: status, account: s, store: store)
            answered = status
        } catch {
            problem = error.localizedDescription
        }
    }
}

private struct PersonRow: View {
    let person: CalPerson
    let note: String?
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(person.label).lineLimit(1)
                if !person.name.isEmpty { Text(person.email).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }
    private var icon: String {
        switch person.status {
        case "ACCEPTED": return "checkmark.circle.fill"
        case "DECLINED": return "xmark.circle.fill"
        case "TENTATIVE": return "questionmark.circle.fill"
        default: return "circle"
        }
    }
    private var tint: Color {
        switch person.status {
        case "ACCEPTED": return .green
        case "DECLINED": return .red
        case "TENTATIVE": return .orange
        default: return .secondary
        }
    }
}

/// Accept, Maybe and Decline, with your current answer picked out.
struct AnswerButtons: View {
    let current: String
    let working: String?
    let answer: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            button("Accept", "ACCEPTED", "checkmark", .green)
            button("Maybe", "TENTATIVE", "questionmark", .orange)
            button("Decline", "DECLINED", "xmark", .red)
        }
    }

    @ViewBuilder private func button(_ title: String, _ status: String, _ icon: String, _ tint: Color) -> some View {
        let on = current == status
        Button { answer(status) } label: {
            HStack(spacing: 5) {
                if working == status { ProgressView().controlSize(.small) } else { Image(systemName: on ? icon + ".circle.fill" : icon) }
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(on ? tint : .secondary)
        .disabled(working != nil)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}


/// Wraps a draft so a sheet can be shown for it.
struct DraftBox: Identifiable {
    let id = UUID()
    let draft: CalendarModel.Draft
}

/// New event, or changing one: title, all day, start and end, calendar, place and notes.
struct EventEditor: View {
    @EnvironmentObject var store: Store
    @ObservedObject var model: CalendarModel
    @State var draft: CalendarModel.Draft
    var saved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var problem: String?

    private var repeats: Bool { draft.editing?.repeats == true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.title)
                    TextField("Place or video call link", text: $draft.location)
                }
                Section {
                    Toggle("All day", isOn: $draft.allDay).disabled(repeats)
                    DatePicker("Starts", selection: $draft.start, displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                        .disabled(repeats)
                        .onChange(of: draft.start) { old, new in
                            // Moving the start moves the end with it, keeping the length.
                            draft.end = draft.end.addingTimeInterval(new.timeIntervalSince(old))
                        }
                    DatePicker("Ends", selection: $draft.end, in: draft.start..., displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                        .disabled(repeats)
                } footer: {
                    if repeats { Text("This event repeats, so its times stay as they are. You can change its title, place and notes.") }
                }
                if draft.editing == nil && model.writableCalendars.count > 1 {
                    Section {
                        Picker("Calendar", selection: $draft.calendarId) {
                            ForEach(model.writableCalendars) { c in
                                HStack {
                                    Circle().fill(model.colour(c)).frame(width: 9, height: 9)
                                    Text(c.name)
                                }
                                .tag(c.id)
                            }
                        }
                    }
                }
                Section("Notes") {
                    TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3...10)
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.editing == nil ? "New event" : "Edit event")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label("Cancel", systemImage: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if working { ProgressView().controlSize(.small) } else { Label("Save", systemImage: "checkmark") }
                    }
                    .disabled(working || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    private func save() async {
        working = true; problem = nil
        defer { working = false }
        do {
            try await model.save(draft, store: store)
            dismiss()
            saved()
        } catch {
            problem = error.localizedDescription
        }
    }
}


/// Which calendars show: a menu of switches, one per calendar.
struct CalendarsMenu: View {
    @EnvironmentObject var store: Store
    @ObservedObject var model: CalendarModel

    var body: some View {
        Menu {
            ForEach(model.shownCalendars) { c in
                Toggle(isOn: Binding(get: { !model.hidden.contains(c.id) }, set: { on in
                    if on { model.hidden.remove(c.id) } else { model.hidden.insert(c.id) }
                })) {
                    if store.accounts.count > 1, let s = store.state(id: c.accountId) {
                        Text("\(c.name) (\(s.account.label))")
                    } else {
                        Text(c.name)
                    }
                }
            }
        } label: {
            Label("Calendars", systemImage: "checklist")
        }
        .help("Choose which calendars show")
        .disabled(model.shownCalendars.isEmpty)
    }
}
