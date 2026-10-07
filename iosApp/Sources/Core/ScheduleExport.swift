import Foundation

/// Port of the schedule exporters in `MaterialPortalActivity.kt`: iCalendar, WakeUp CSV and the
/// raw JSON.
///
/// All three read the same inputs -- the semester's start date, the day list, and the per-section
/// clock times from the school profile's `unitTimes` -- because a calendar entry without real times
/// is worse than no entry at all: it shows up at the wrong hour and silently misleads.
enum ScheduleExport {
    /// One resolved lesson, independent of which format it is about to be rendered into.
    struct Entry {
        let title: String
        let code: String
        let teacher: String
        let location: String
        /// 1 = Monday ... 7 = Sunday, matching the iCalendar `BYDAY` codes' offset.
        let weekday: Int
        let startDate: Date
        let endDate: Date
        let firstWeek: Int
        let lastWeek: Int
    }

    /// The export formats the Android client offers, in the same order.
    enum Format: String, CaseIterable, Identifiable {
        case iCalendar
        case wakeUpCSV
        case json

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .iCalendar: return "iCalendar (.ics)"
            case .wakeUpCSV: return "WakeUp (.csv)"
            case .json: return "JSON"
            }
        }

        var systemImage: String {
            switch self {
            case .iCalendar: return "calendar"
            case .wakeUpCSV: return "tablecells"
            case .json: return "curlybraces"
            }
        }

        var fileExtension: String {
            switch self {
            case .iCalendar: return "ics"
            case .wakeUpCSV: return "csv"
            case .json: return "json"
            }
        }
    }

    // MARK: - Entry resolution

    /// Flattens the published schedule into dated entries.
    ///
    /// `unitTimes` maps a section name to its start and end clock time; a lesson that names sections
    /// the school never defined falls back to the times the reader published on the lesson itself,
    /// and only then to a placeholder, so a missing profile degrades one entry rather than the file.
    static func entries(
        semesterStartDate: String,
        days: [ScheduleDay],
        unitTimes: [String: (start: String, end: String)]
    ) -> [Entry] {
        let start = Self.parseISODate(semesterStartDate) ?? Self.startOfCurrentWeek()
        var result: [Entry] = []

        for (dayIndex, day) in days.enumerated() {
            let weekday = Self.weekdayIndex(from: day.name) ?? dayIndex + 1
            guard (1...7).contains(weekday) else { continue }

            for lesson in day.lessons {
                guard let schedule = lesson.schedule else { continue }
                let times = Self.resolveTimes(schedule, unitTimes: unitTimes)
                let weeks = Self.parseWeeks(schedule.weeks)

                result.append(
                    Entry(
                        title: lesson.title,
                        code: lesson.subtitle,
                        teacher: schedule.teacher,
                        location: schedule.location,
                        weekday: weekday,
                        startDate: Self.date(inWeek: weeks.lowerBound, weekday: weekday, semesterStart: start, time: times.start),
                        endDate: Self.date(inWeek: weeks.upperBound, weekday: weekday, semesterStart: start, time: times.end),
                        firstWeek: weeks.lowerBound,
                        lastWeek: weeks.upperBound
                    )
                )
            }
        }
        return result
    }

    // MARK: - Renderers

    static func render(_ format: Format, semester: String, entries: [Entry]) -> String {
        switch format {
        case .iCalendar: return ics(semester: semester, entries: entries)
        case .wakeUpCSV: return wakeUpCSV(semester: semester, entries: entries)
        case .json: return json(semester: semester, entries: entries)
        }
    }

    private static func ics(semester: String, entries: [Entry]) -> String {
        let stamp = Self.icsStamp(Date())
        let name = semester.isEmpty ? "掌上教务课表" : semester
        var out = """
        BEGIN:VCALENDAR\r
        VERSION:2.0\r
        PRODID:-//PalmAcademic//Schedule//ZH-CN\r
        CALSCALE:GREGORIAN\r
        METHOD:PUBLISH\r
        X-WR-CALNAME:\(escape(name))\r
        X-WR-TIMEZONE:Asia/Shanghai\r

        """
        for entry in entries {
            out += "BEGIN:VEVENT\r\n"
            out += "UID:\(entry.startDate.timeIntervalSince1970)-\(abs(entry.title.hashValue))@palmacademic\r\n"
            out += "DTSTAMP:\(stamp)\r\n"
            out += "DTSTART;TZID=Asia/Shanghai:\(icsStamp(entry.startDate))\r\n"
            out += "DTEND;TZID=Asia/Shanghai:\(icsStamp(entry.endDate))\r\n"
            out += "SUMMARY:\(escape(entry.title))\r\n"
            if !entry.code.isEmpty { out += "DESCRIPTION:\(escape(entry.code))\r\n" }
            if !entry.teacher.isEmpty { out += "X-TEACHER:\(escape(entry.teacher))\r\n" }
            if !entry.location.isEmpty { out += "LOCATION:\(escape(entry.location))\r\n" }
            var rrule = "RRULE:FREQ=WEEKLY;BYDAY=\(byDay(entry.weekday))"
            if entry.lastWeek >= entry.firstWeek {
                rrule += ";UNTIL=\(icsStamp(Self.date(inWeek: entry.lastWeek, weekday: entry.weekday, semesterStart: Self.startOfCurrentWeek(), time: "23:59")))"
            }
            out += rrule + "\r\n"
            out += "END:VEVENT\r\n"
        }
        out += "END:VCALENDAR\r\n"
        return out
    }

    private static func wakeUpCSV(semester: String, entries: [Entry]) -> String {
        // WakeUp reads a header row and one row per lesson; the semicolon separator is what the
        // app's importer expects.
        var rows = ["Title,Start Date,Start Time,End Date,End Time,Location,Notes"]
        for entry in entries.sorted(by: { ($0.startDate, $0.title) < ($1.startDate, $1.title) }) {
            rows.append([
                csvField(entry.title),
                dayFormatter.string(from: entry.startDate),
                timeFormatter.string(from: entry.startDate),
                dayFormatter.string(from: entry.endDate),
                timeFormatter.string(from: entry.endDate),
                csvField(entry.location),
                csvField([entry.code, entry.teacher].filter { !$0.isEmpty }.joined(separator: " · "))
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private static func json(semester: String, entries: [Entry]) -> String {
        let items = entries.map { entry -> [String: Any] in
            var object: [String: Any] = [
                "title": entry.title,
                "weekday": entry.weekday,
                "start": isoFormatter.string(from: entry.startDate),
                "end": isoFormatter.string(from: entry.endDate),
                "firstWeek": entry.firstWeek,
                "lastWeek": entry.lastWeek
            ]
            if !entry.code.isEmpty { object["code"] = entry.code }
            if !entry.teacher.isEmpty { object["teacher"] = entry.teacher }
            if !entry.location.isEmpty { object["location"] = entry.location }
            return object
        }
        let root: [String: Any] = ["semester": semester, "lessons": items]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    // MARK: - Files

    /// Writes an export into a temporary file so it can be handed to the share sheet.
    static func write(_ format: Format, semester: String, entries: [Entry], schoolID: String) -> URL? {
        let text = render(format, semester: semester, entries: entries)
        let name = "课表-\(semester.isEmpty ? schoolID : semester).\(format.fileExtension)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Parsing helpers

    /// Accepts "1-16周", "1-16", "第1-16周" and single values, defaulting to a single week when
    /// the text cannot be read rather than dropping the lesson.
    static func parseWeeks(_ text: String) -> ClosedRange<Int> {
        // `Scanner.scanIntegers` is not part of the Darwin Foundation surface, so the digits are
        // pulled out directly. "1-16周", "第1-16周" and "1,2" all reduce to the same pair.
        let numbers = text.compactMap { $0.wholeNumberValue }
        if let first = numbers.first, let last = numbers.dropFirst().first, last >= first {
            return first...last
        }
        if let only = numbers.first { return only...only }
        return 1...1
    }

    private static func resolveTimes(
        _ schedule: MaterialCourseSchedule,
        unitTimes: [String: (start: String, end: String)]
    ) -> (start: String, end: String) {
        if let mapped = unitTimes[schedule.startSection], let end = unitTimes[schedule.endSection] {
            return (mapped.start, end.end)
        }
        let start = schedule.startTime.isEmpty ? "08:00" : schedule.startTime
        let end = schedule.endTime.isEmpty ? "09:40" : schedule.endTime
        return (start, end)
    }

    private static func weekdayIndex(from name: String) -> Int? {
        let cleaned = name.replacingOccurrences(of: "星期", with: "")
            .replacingOccurrences(of: "周", with: "")
        let map = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "日": 7, "天": 7]
        if let digit = Int(cleaned), (1...7).contains(digit) { return digit }
        for (character, index) in map {
            if cleaned.contains(character) { return index }
        }
        return nil
    }

    private static func parseISODate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    /// The Monday of the current week, used when the semester start is unknown.
    static func startOfCurrentWeek() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        return calendar.date(from: components) ?? Date()
    }

    private static func date(inWeek week: Int, weekday: Int, semesterStart: Date, time: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        // `semesterStart` is the first Monday of term; weekday 1 is Monday itself.
        let offset = (max(week, 1) - 1) * 7 + (max(weekday, 1) - 1)
        let day = calendar.date(byAdding: .day, value: offset, to: semesterStart) ?? semesterStart
        let parts = time.split(separator: ":").compactMap { Int($0) }
        let hour = parts.count > 0 ? parts[0] : 8
        let minute = parts.count > 1 ? parts[1] : 0
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    private static func byDay(_ weekday: Int) -> String {
        ["MO", "TU", "WE", "TH", "FR", "SA", "SU"][max(1, min(7, weekday)) - 1]
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func icsStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter
    }()
}
