// Calendar files (iCalendar, RFC 5545): reading them into events, working out repeating events, and writing a file
// back after answering an invitation. Only what a day and week calendar needs; anything we don't understand is kept
// as it came, so a file we write back loses nothing.

import Foundation

/// One line of a calendar file: NAME;PARAM=VALUE:value. The value is kept escaped, exactly as it came.
struct ICalProperty {
    var name: String
    /// Parameters in their original order and quoting, so writing them back changes nothing we didn't mean to.
    var rawParams: [(String, String)]
    var raw: String

    func param(_ key: String) -> String? {
        rawParams.first { $0.0.uppercased() == key }?.1.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
    mutating func setParam(_ key: String, _ value: String) {
        if let i = rawParams.firstIndex(where: { $0.0.uppercased() == key }) { rawParams[i].1 = value }
        else { rawParams.append((key, value)) }
    }
    /// The value with \n, \, and \; turned back into what they stand for.
    var text: String {
        var out = ""
        var escaping = false
        for ch in raw {
            if escaping {
                out.append(ch == "n" || ch == "N" ? "\n" : ch)
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        return out
    }
}

final class ICalComponent {
    let name: String
    var properties: [ICalProperty] = []
    var children: [ICalComponent] = []
    init(_ name: String) { self.name = name }

    func prop(_ n: String) -> ICalProperty? { properties.first { $0.name == n } }
    func props(_ n: String) -> [ICalProperty] { properties.filter { $0.name == n } }
    func text(_ n: String) -> String? { prop(n)?.text }
    var events: [ICalComponent] { children.filter { $0.name == "VEVENT" } }
}

enum ICal {
    // MARK: Reading

    static func parse(_ text: String) -> ICalComponent? {
        // Unfold: a line starting with a space or tab carries on the one before.
        var lines: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            if let f = line.first, f == " " || f == "\t", !lines.isEmpty { lines[lines.count - 1] += line.dropFirst() }
            else if !line.isEmpty { lines.append(line) }
        }
        let root = ICalComponent("#root")
        var stack = [root]
        for line in lines {
            guard let p = property(line) else { continue }
            if p.name == "BEGIN" {
                let c = ICalComponent(p.raw.uppercased())
                stack.last?.children.append(c)
                stack.append(c)
            } else if p.name == "END" {
                if stack.count > 1 { stack.removeLast() }
            } else {
                stack.last?.properties.append(p)
            }
        }
        return root.children.first { $0.name == "VCALENDAR" }
    }

    /// Splits NAME;A=1;B="x:y":value, minding quoted parameter values that can hold : and ;.
    static func property(_ line: String) -> ICalProperty? {
        var name = ""
        var params: [(String, String)] = []
        var current = ""
        var quoted = false
        var inName = true
        var valueStart: String.Index?
        var i = line.startIndex
        func finishParam() {
            if let eq = current.firstIndex(of: "=") {
                params.append((String(current[..<eq]), String(current[current.index(after: eq)...])))
            }
            current = ""
        }
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" { quoted.toggle(); current.append(ch) }
            else if !quoted && (ch == ";" || ch == ":") {
                if inName { name = current; current = ""; inName = false } else { finishParam() }
                if ch == ":" { valueStart = line.index(after: i); break }
            } else { current.append(ch) }
            i = line.index(after: i)
        }
        guard let v = valueStart, !name.isEmpty else { return nil }
        return ICalProperty(name: name.uppercased(), rawParams: params, raw: String(line[v...]))
    }

    // MARK: Writing

    static func serialize(_ c: ICalComponent) -> String {
        var out: [String] = ["BEGIN:\(c.name)"]
        for p in c.properties {
            var line = p.name
            for (k, v) in p.rawParams { line += ";\(k)=\(v)" }
            line += ":" + p.raw
            out.append(fold(line))
        }
        for child in c.children { out.append(serialize(child)) }
        out.append("END:\(c.name)")
        return out.joined(separator: "\r\n") + (c.name == "VCALENDAR" ? "\r\n" : "")
    }

    /// Lines longer than 75 bytes are folded, never splitting a character.
    private static func fold(_ line: String) -> String {
        guard line.utf8.count > 75 else { return line }
        var parts: [String] = []
        var current = ""
        var bytes = 0
        for ch in line {
            let n = String(ch).utf8.count
            if bytes + n > (parts.isEmpty ? 75 : 74) { parts.append(current); current = ""; bytes = 0 }
            current.append(ch)
            bytes += n
        }
        parts.append(current)
        return parts.joined(separator: "\r\n ")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: Dates

    struct When {
        let date: Date
        let allDay: Bool
        let zone: TimeZone
    }

    private static let utcStamp: DateFormatter = formatter("yyyyMMdd'T'HHmmss'Z'", TimeZone(identifier: "UTC")!)
    private static func formatter(_ f: String, _ tz: TimeZone) -> DateFormatter {
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.calendar = Calendar(identifier: .gregorian)
        d.timeZone = tz
        d.dateFormat = f
        return d
    }

    static func stamp(_ d: Date) -> String { utcStamp.string(from: d) }

    /// A date property (DTSTART, DTEND, RECURRENCE-ID, EXDATE) read as a moment, with its time zone.
    static func when(_ p: ICalProperty, value: String? = nil) -> When? {
        let v = (value ?? p.raw).trimmingCharacters(in: .whitespaces)
        let zone = p.param("TZID").flatMap(timeZone) ?? .current
        if p.param("VALUE") == "DATE" || (v.count == 8 && !v.contains("T")) {
            guard let d = formatter("yyyyMMdd", .current).date(from: String(v.prefix(8))) else { return nil }
            return When(date: d, allDay: true, zone: .current)
        }
        if v.hasSuffix("Z") {
            guard let d = utcStamp.date(from: v) else { return nil }
            return When(date: d, allDay: false, zone: p.param("TZID").flatMap(timeZone) ?? .current)
        }
        guard let d = formatter("yyyyMMdd'T'HHmmss", zone).date(from: String(v.prefix(15))) else { return nil }
        return When(date: d, allDay: false, zone: zone)
    }

    /// Olson names (Europe/London), the long forms some servers use (/mozilla.org/.../Europe/London), and the
    /// Windows names Outlook sends. Unknown names fall back to the device's own zone.
    static func timeZone(_ name: String) -> TimeZone? {
        if let z = TimeZone(identifier: name) { return z }
        let parts = name.split(separator: "/")
        if parts.count >= 2, let z = TimeZone(identifier: parts.suffix(2).joined(separator: "/")) { return z }
        if parts.count >= 3, let z = TimeZone(identifier: parts.suffix(3).joined(separator: "/")) { return z }
        let windows: [String: String] = [
            "GMT Standard Time": "Europe/London", "Greenwich Standard Time": "Atlantic/Reykjavik",
            "W. Europe Standard Time": "Europe/Berlin", "Romance Standard Time": "Europe/Paris",
            "Central Europe Standard Time": "Europe/Budapest", "Central European Standard Time": "Europe/Warsaw",
            "E. Europe Standard Time": "Europe/Bucharest", "FLE Standard Time": "Europe/Helsinki",
            "Eastern Standard Time": "America/New_York", "Central Standard Time": "America/Chicago",
            "Mountain Standard Time": "America/Denver", "Pacific Standard Time": "America/Los_Angeles",
            "US Mountain Standard Time": "America/Phoenix", "Atlantic Standard Time": "America/Halifax",
            "AUS Eastern Standard Time": "Australia/Sydney", "E. Australia Standard Time": "Australia/Brisbane",
            "New Zealand Standard Time": "Pacific/Auckland", "India Standard Time": "Asia/Kolkata",
            "China Standard Time": "Asia/Shanghai", "Tokyo Standard Time": "Asia/Tokyo",
            "Singapore Standard Time": "Asia/Singapore", "Arabian Standard Time": "Asia/Dubai",
            "South Africa Standard Time": "Africa/Johannesburg", "UTC": "UTC", "Coordinated Universal Time": "UTC",
        ]
        return windows[name].flatMap(TimeZone.init(identifier:))
    }

    /// P1D, PT1H30M, -PT15M and so on, in seconds.
    static func duration(_ s: String) -> TimeInterval? {
        var sign: Double = 1
        var str = Substring(s)
        if str.first == "-" { sign = -1; str = str.dropFirst() } else if str.first == "+" { str = str.dropFirst() }
        guard str.first == "P" else { return nil }
        str = str.dropFirst()
        var total: Double = 0
        var number = ""
        for ch in str {
            if ch.isNumber { number.append(ch); continue }
            let n = Double(number) ?? 0
            number = ""
            switch ch {
            case "W": total += n * 7 * 86_400
            case "D": total += n * 86_400
            case "H": total += n * 3_600
            case "M": total += n * 60
            case "S": total += n
            default: break
            }
        }
        return sign * total
    }

    // MARK: Repeating events

    struct Rule {
        enum Freq: String { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }
        var freq: Freq
        var interval = 1
        var count: Int?
        var until: Date?
        var byDay: [(ordinal: Int?, weekday: Int)] = []   // weekday 1 = Sunday, as Calendar counts
        var byMonthDay: [Int] = []
        var byMonth: [Int] = []
        var bySetPos: [Int] = []
        var weekStart = 2

        init?(_ raw: String, zone: TimeZone) {
            var parts: [String: String] = [:]
            for p in raw.split(separator: ";") {
                let kv = p.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { parts[kv[0].uppercased()] = String(kv[1]) }
            }
            guard let f = parts["FREQ"].flatMap({ Freq(rawValue: $0.uppercased()) }) else { return nil }
            freq = f
            interval = max(1, Int(parts["INTERVAL"] ?? "") ?? 1)
            count = parts["COUNT"].flatMap { Int($0) }
            if let u = parts["UNTIL"] {
                let p = ICalProperty(name: "UNTIL", rawParams: [], raw: u)
                until = ICal.when(p)?.date
                if let d = until, u.count == 8 { until = d.addingTimeInterval(86_399) }   // a date means to the end of that day
            }
            byDay = (parts["BYDAY"] ?? "").split(separator: ",").compactMap { d in
                let s = String(d)
                guard s.count >= 2, let wd = Rule.weekday(String(s.suffix(2))) else { return nil }
                let n = s.dropLast(2)
                return (n.isEmpty ? nil : Int(n), wd)
            }
            byMonthDay = (parts["BYMONTHDAY"] ?? "").split(separator: ",").compactMap { Int($0) }
            byMonth = (parts["BYMONTH"] ?? "").split(separator: ",").compactMap { Int($0) }
            bySetPos = (parts["BYSETPOS"] ?? "").split(separator: ",").compactMap { Int($0) }
            weekStart = parts["WKST"].flatMap(Rule.weekday) ?? 2
        }

        static func weekday(_ s: String) -> Int? {
            ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7][s.uppercased()]
        }
    }

    /// The start of every time an event happens, from its first start up to `limit`, following its rule.
    /// Counted from the very first time, so COUNT works however far into the series we look.
    static func starts(from first: Date, rule: Rule, zone: TimeZone, allDay: Bool, limit: Date) -> [Date] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        cal.firstWeekday = rule.weekStart
        let time = cal.dateComponents([.hour, .minute, .second], from: first)
        let firstDay = cal.dateComponents([.year, .month, .day], from: first)
        var out: [Date] = []
        var n = 0

        func make(_ y: Int, _ m: Int, _ d: Int) -> Date? {
            var c = DateComponents(year: y, month: m, day: d, hour: allDay ? 0 : time.hour, minute: allDay ? 0 : time.minute,
                                   second: allDay ? 0 : time.second)
            c.calendar = cal
            // Reject days that don't exist (31 June rolls into July otherwise).
            guard let date = cal.date(from: c), cal.component(.day, from: date) == d else { return nil }
            return date
        }
        func daysIn(_ y: Int, _ m: Int) -> Int {
            cal.range(of: .day, in: .month, for: cal.date(from: DateComponents(year: y, month: m, day: 1))!)?.count ?? 30
        }
        /// Days of a month picked by BYMONTHDAY and BYDAY (with "2nd Tuesday" and "last Friday").
        func monthDays(_ y: Int, _ m: Int) -> [Int] {
            let count = daysIn(y, m)
            let weekdayOf: (Int) -> Int = { d in cal.component(.weekday, from: cal.date(from: DateComponents(year: y, month: m, day: d))!) }
            var days: [Int]
            if !rule.byMonthDay.isEmpty {
                days = rule.byMonthDay.map { $0 > 0 ? $0 : count + $0 + 1 }.filter { (1...count).contains($0) }
                if !rule.byDay.isEmpty { days = days.filter { d in rule.byDay.contains { $0.weekday == weekdayOf(d) } } }
            } else if !rule.byDay.isEmpty {
                days = []
                for b in rule.byDay {
                    let matching = (1...count).filter { weekdayOf($0) == b.weekday }
                    if let o = b.ordinal {
                        let i = o > 0 ? o - 1 : matching.count + o
                        if matching.indices.contains(i) { days.append(matching[i]) }
                    } else {
                        days += matching
                    }
                }
            } else {
                days = [firstDay.day ?? 1].filter { $0 <= count }
            }
            return Array(Set(days)).sorted()
        }

        let y0 = firstDay.year ?? 2000, m0 = firstDay.month ?? 1
        let weekOne = cal.dateInterval(of: .weekOfYear, for: first)?.start ?? first
        for period in 0..<20_000 {
            var candidates: [Date] = []
            var periodStart: Date?
            switch rule.freq {
            case .daily:
                guard let day = cal.date(byAdding: .day, value: period * rule.interval, to: cal.startOfDay(for: first)) else { break }
                periodStart = day
                let c = cal.dateComponents([.year, .month, .day, .weekday], from: day)
                if !rule.byMonth.isEmpty && !rule.byMonth.contains(c.month!) { break }
                if !rule.byMonthDay.isEmpty && !rule.byMonthDay.contains(c.day!) { break }
                if !rule.byDay.isEmpty && !rule.byDay.contains(where: { $0.weekday == c.weekday! }) { break }
                if let d = make(c.year!, c.month!, c.day!) { candidates = [d] }
            case .weekly:
                guard let start = cal.date(byAdding: .day, value: 7 * period * rule.interval, to: weekOne) else { break }
                periodStart = start
                let weekdays = rule.byDay.isEmpty ? [cal.component(.weekday, from: first)] : rule.byDay.map(\.weekday)
                for offset in 0..<7 {
                    guard let day = cal.date(byAdding: .day, value: offset, to: start) else { continue }
                    let c = cal.dateComponents([.year, .month, .day, .weekday], from: day)
                    guard weekdays.contains(c.weekday!) else { continue }
                    if !rule.byMonth.isEmpty && !rule.byMonth.contains(c.month!) { continue }
                    if let d = make(c.year!, c.month!, c.day!) { candidates.append(d) }
                }
            case .monthly:
                let total = (m0 - 1) + period * rule.interval
                let y = y0 + total / 12, m = total % 12 + 1
                periodStart = cal.date(from: DateComponents(year: y, month: m, day: 1))
                if !rule.byMonth.isEmpty && !rule.byMonth.contains(m) { break }
                candidates = monthDays(y, m).compactMap { make(y, m, $0) }
            case .yearly:
                let y = y0 + period * rule.interval
                periodStart = cal.date(from: DateComponents(year: y, month: 1, day: 1))
                for m in (rule.byMonth.isEmpty ? [m0] : rule.byMonth.sorted()) {
                    candidates += monthDays(y, m).compactMap { make(y, m, $0) }
                }
            }
            candidates.sort()
            if !rule.bySetPos.isEmpty {
                let all = candidates
                candidates = rule.bySetPos.compactMap { p in
                    let i = p > 0 ? p - 1 : all.count + p
                    return all.indices.contains(i) ? all[i] : nil
                }.sorted()
            }
            for c in candidates where c >= first {
                if let u = rule.until, c > u { return out }
                n += 1
                if let max = rule.count, n > max { return out }
                if c > limit { return out }
                out.append(c)
            }
            // Past the window: nothing more to find.
            if let p = periodStart, p > limit { return out }
            if periodStart == nil { return out }
        }
        return out
    }
}
