import Foundation

/// Schedule exporters kept intentionally equivalent to Android's `MaterialPortalActivity`.
/// iCalendar expands every teaching week into its own event, WakeUp keeps the official seven
/// column import shape, and JSON preserves the adapter's day/field hierarchy.
enum ScheduleExport {
    struct Occurrence {
        let week: Int
        let startDate: Date
        let endDate: Date
    }

    struct Entry {
        let title: String
        let code: String
        let teacher: String
        let location: String
        /// 1 = Monday ... 7 = Sunday.
        let weekday: Int
        let startSection: String
        let endSection: String
        let weeks: String
        let occurrences: [Occurrence]
    }

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

    static func entries(
        semesterStartDate: String,
        days: [ScheduleDay],
        unitTimes: [String: (start: String, end: String)]
    ) -> [Entry] {
        let semesterStart = parseISODate(semesterStartDate) ?? startOfCurrentWeek()
        var result: [Entry] = []

        for (dayIndex, day) in days.enumerated() {
            let weekday = weekdayIndex(from: day.name) ?? dayIndex + 1
            guard (1...7).contains(weekday) else { continue }

            for lesson in day.lessons {
                guard let schedule = resolvedSchedule(for: lesson) else { continue }
                let times = resolveTimes(schedule, unitTimes: unitTimes)
                let weeks = expandWeeks(schedule.weeks)
                let resolvedWeeks = weeks.isEmpty ? [1] : weeks
                let occurrences = resolvedWeeks.map { week in
                    let day = date(
                        inWeek: week,
                        weekday: weekday,
                        semesterStart: semesterStart,
                        time: times.start
                    )
                    return Occurrence(
                        week: week,
                        startDate: day,
                        endDate: date(
                            inWeek: week,
                            weekday: weekday,
                            semesterStart: semesterStart,
                            time: times.end
                        )
                    )
                }
                result.append(Entry(
                    title: lesson.title,
                    code: lesson.subtitle,
                    teacher: schedule.teacher,
                    location: schedule.location,
                    weekday: weekday,
                    startSection: schedule.startSection,
                    endSection: schedule.endSection,
                    weeks: schedule.weeks,
                    occurrences: occurrences
                ))
            }
        }
        return result
    }

    static func render(
        _ format: Format,
        semester: String,
        semesterStartDate: String,
        days: [ScheduleDay],
        unitTimes: [String: (start: String, end: String)]
    ) -> String {
        let resolvedEntries = entries(
            semesterStartDate: semesterStartDate,
            days: days,
            unitTimes: unitTimes
        )
        switch format {
        case .iCalendar:
            return ics(semester: semester, entries: resolvedEntries)
        case .wakeUpCSV:
            return wakeUpCSV(entries: resolvedEntries)
        case .json:
            return json(semester: semester, semesterStartDate: semesterStartDate, days: days)
        }
    }

    private static func ics(semester: String, entries: [Entry]) -> String {
        let stamp = utcStamp(Date())
        let name = semester.isEmpty ? "掌上教务课表" : semester
        var output = "BEGIN:VCALENDAR\r\n"
        output += "VERSION:2.0\r\n"
        output += "PRODID:-//PalmAcademic//Schedule//ZH-CN\r\n"
        output += "CALSCALE:GREGORIAN\r\n"
        output += "METHOD:PUBLISH\r\n"
        output += "X-WR-CALNAME:\(escape(name))\r\n"
        output += "X-WR-TIMEZONE:Asia/Shanghai\r\n"
        output += "BEGIN:VTIMEZONE\r\nTZID:Asia/Shanghai\r\n"
        output += "BEGIN:STANDARD\r\nDTSTART:19700101T000000\r\n"
        output += "TZOFFSETFROM:+0800\r\nTZOFFSETTO:+0800\r\nTZNAME:CST\r\n"
        output += "END:STANDARD\r\nEND:VTIMEZONE\r\n"

        for entry in entries {
            for occurrence in entry.occurrences {
                let uidSource = [
                    semester, String(entry.weekday), entry.title, entry.code, entry.weeks,
                    entry.startSection, entry.endSection, entry.teacher, entry.location,
                    String(occurrence.week)
                ].joined(separator: "|")
                let description = [
                    entry.code,
                    sectionDescription(start: entry.startSection, end: entry.endSection),
                    entry.weeks.isEmpty ? "" : "第\(entry.weeks)周",
                    entry.teacher.isEmpty ? "" : "老师：\(entry.teacher)"
                ].filter { !$0.isEmpty }.joined(separator: " | ")

                output += "BEGIN:VEVENT\r\n"
                output += "UID:\(stableHash(uidSource))-\(occurrence.week)@palmacademic\r\n"
                output += "DTSTAMP:\(stamp)\r\n"
                output += "DTSTART;TZID=Asia/Shanghai:\(localStamp(occurrence.startDate))\r\n"
                output += "DTEND;TZID=Asia/Shanghai:\(localStamp(occurrence.endDate))\r\n"
                output += "SUMMARY:\(escape(entry.title))\r\n"
                if !entry.location.isEmpty { output += "LOCATION:\(escape(entry.location))\r\n" }
                output += "DESCRIPTION:\(escape(description))\r\n"
                output += "END:VEVENT\r\n"
            }
        }
        output += "END:VCALENDAR\r\n"
        return output
    }

    private static func wakeUpCSV(entries: [Entry]) -> String {
        var rows = ["课程名称,星期,开始节数,结束节数,老师,地点,周数"]
        for entry in entries {
            rows.append([
                entry.title,
                String(entry.weekday),
                entry.startSection,
                entry.endSection,
                entry.teacher,
                entry.location,
                entry.weeks
            ].map(csvField).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private static func json(
        semester: String,
        semesterStartDate: String,
        days: [ScheduleDay]
    ) -> String {
        let encodedDays: [[String: Any]] = days.map { day in
            let lessons: [[String: Any]] = day.lessons.map { lesson in
                let fields = Dictionary(lesson.fields.map { ($0.label, $0.value) }, uniquingKeysWith: { _, last in last })
                return [
                    "name": lesson.title,
                    "code": lesson.subtitle,
                    "fields": fields
                ]
            }
            return ["day": day.name, "lessons": lessons]
        }
        let root: [String: Any] = [
            "semester": semester,
            "semesterStartDate": semesterStartDate,
            "days": encodedDays
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func write(
        _ format: Format,
        semester: String,
        semesterStartDate: String,
        days: [ScheduleDay],
        unitTimes: [String: (start: String, end: String)],
        schoolID: String
    ) -> URL? {
        let text = render(
            format,
            semester: semester,
            semesterStartDate: semesterStartDate,
            days: days,
            unitTimes: unitTimes
        )
        let baseName = semester.isEmpty ? schoolID : semester
        let prefix = format == .wakeUpCSV ? "WakeUp课程表-" : ""
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(baseName).\(format.fileExtension)")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Android-compatible week expansion: supports ranges, comma/顿号-separated fragments, and
    /// odd/even qualifiers such as `1-16单周`, `2-16（双）` and `1,3,5周`.
    static func expandWeeks(_ value: String) -> [Int] {
        var normalized = value
            .replacingOccurrences(of: "（", with: "")
            .replacingOccurrences(of: "）", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "周", with: "")
        normalized = normalized.replacingOccurrences(of: "[~～—至]", with: "-", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: "[,，;；]", with: "、", options: .regularExpression)

        let pattern = #"^(\d+)\s*(?:-\s*(\d+))?\s*(单|双)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var weeks: Set<Int> = []
        for rawToken in normalized.split(separator: "、") {
            let token = String(rawToken).trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(token.startIndex..<token.endIndex, in: token)
            guard let match = regex.firstMatch(in: token, range: range),
                  let startRange = Range(match.range(at: 1), in: token),
                  let start = Int(token[startRange]) else { continue }
            let end: Int
            if match.range(at: 2).location != NSNotFound,
               let endRange = Range(match.range(at: 2), in: token),
               let parsedEnd = Int(token[endRange]) {
                end = parsedEnd
            } else {
                end = start
            }
            let parity: String
            if match.range(at: 3).location != NSNotFound,
               let parityRange = Range(match.range(at: 3), in: token) {
                parity = String(token[parityRange])
            } else {
                parity = ""
            }
            for week in min(start, end)...max(start, end) where week > 0 {
                if parity == "单", week.isMultiple(of: 2) { continue }
                if parity == "双", !week.isMultiple(of: 2) { continue }
                weeks.insert(week)
            }
        }
        return weeks.sorted()
    }

    private static func resolveTimes(
        _ schedule: MaterialCourseSchedule,
        unitTimes: [String: (start: String, end: String)]
    ) -> (start: String, end: String) {
        let times = defaultUnitTimes.merging(unitTimes) { _, schoolValue in schoolValue }
        let explicitStart = schedule.startTime.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitEnd = schedule.endTime.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = explicitStart.isEmpty ? times[schedule.startSection]?.start : explicitStart
        let end = explicitEnd.isEmpty ? times[schedule.endSection]?.end : explicitEnd
        return (start ?? "08:00", end ?? "09:40")
    }

    /// Android also exports older adapter payloads whose structured `schedule` object is absent
    /// but whose card fields still carry the same data. Keep that compatibility path here so CSV,
    /// JSON and ICS do not silently disagree about how many lessons exist.
    private static func resolvedSchedule(for lesson: MaterialCardItem) -> MaterialCourseSchedule? {
        if let schedule = lesson.schedule { return schedule }
        let fields = Dictionary(lesson.fields.map { ($0.label, $0.value) }, uniquingKeysWith: { _, last in last })
        let raw = fields["时间与地点"] ?? ""
        let sectionSource = fields["节次"] ?? raw
        let sectionMatch = captures(#"(?:第\s*)?(\d+)\s*[-~～—至]\s*(\d+)\s*节?"#, in: sectionSource)
        let singleSection = captures(#"(?:第\s*)?(\d+)\s*节"#, in: sectionSource)
        let rangedStart = sectionMatch.flatMap { $0.first }.flatMap(nonEmpty)
        let rangedEnd = sectionMatch.flatMap { $0.dropFirst().first }.flatMap(nonEmpty)
        let single = singleSection.flatMap { $0.first }.flatMap(nonEmpty)
        let startSection = fields["开始节数"].flatMap(nonEmpty)
            ?? rangedStart
            ?? single
            ?? ""
        let endSection = fields["结束节数"].flatMap(nonEmpty)
            ?? rangedEnd
            ?? single
            ?? startSection
        guard !startSection.isEmpty else { return nil }

        let weeks = fields["周数"].flatMap(nonEmpty) ?? extractWeekText(from: raw)
        let teacher = fields["老师"].flatMap(nonEmpty)
            ?? fields["教师"].flatMap(nonEmpty)
            ?? firstCapture(#"(?:教师|老师)\s*[:：]\s*([^·|,，;；]+)"#, in: raw)
            ?? ""
        let location = fields["地点"].flatMap(nonEmpty)
            ?? fields["教室"].flatMap(nonEmpty)
            ?? firstCapture(#"(?:地点|教室|上课地点)\s*[:：]\s*([^·|,，;；]+)"#, in: raw)
            ?? ""
        return MaterialCourseSchedule(
            weeks: weeks,
            startSection: startSection,
            endSection: endSection,
            teacher: teacher,
            location: location,
            startTime: fields["开始时间"] ?? "",
            endTime: fields["结束时间"] ?? ""
        )
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func captures(_ pattern: String, in value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func firstCapture(_ pattern: String, in value: String) -> String? {
        captures(pattern, in: value)?.first.flatMap(nonEmpty)
    }

    private static func extractWeekText(from value: String) -> String {
        let pattern = #"(\d+)(?:\s*[-~～—至]\s*(\d+))?\s*(?:(单|双)\s*)?周\s*(?:[（(]?\s*(单|双)\s*[）)]?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        var seen: Set<String> = []
        return regex.matches(in: value, range: range).compactMap { match in
            func group(_ index: Int) -> String {
                guard match.range(at: index).location != NSNotFound,
                      let range = Range(match.range(at: index), in: value) else { return "" }
                return String(value[range])
            }
            guard let startRange = Range(match.range(at: 1), in: value) else { return nil }
            let start = String(value[startRange])
            let end = group(2)
            let firstParity = group(3)
            let secondParity = group(4)
            return start + (end.isEmpty || end == start ? "" : "-\(end)") + (firstParity.isEmpty ? secondParity : firstParity)
        }.filter { seen.insert($0).inserted }.joined(separator: "、")
    }

    private static let defaultUnitTimes: [String: (start: String, end: String)] = [
        "1": ("09:30", "10:15"), "2": ("10:20", "11:05"),
        "3": ("11:25", "12:10"), "4": ("12:15", "13:00"),
        "5": ("13:05", "13:50"), "6": ("16:00", "16:45"),
        "7": ("16:50", "17:35"), "8": ("17:55", "18:40"),
        "9": ("18:45", "19:30"), "10": ("20:30", "21:15"),
        "11": ("21:20", "22:05"), "12": ("22:10", "22:55")
    ]

    private static func weekdayIndex(from name: String) -> Int? {
        let cleaned = name
            .replacingOccurrences(of: "星期", with: "")
            .replacingOccurrences(of: "周", with: "")
        let map = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "日": 7, "天": 7]
        if let digit = Int(cleaned), (1...7).contains(digit) { return digit }
        return map.first(where: { cleaned.contains($0.key) })?.value
    }

    private static func parseISODate(_ text: String) -> Date? {
        dayFormatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func startOfCurrentWeek() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghaiTimeZone
        calendar.firstWeekday = 2
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        return calendar.date(from: components) ?? Date()
    }

    private static func date(
        inWeek week: Int,
        weekday: Int,
        semesterStart: Date,
        time: String
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghaiTimeZone
        let offset = (max(week, 1) - 1) * 7 + (max(weekday, 1) - 1)
        let day = calendar.date(byAdding: .day, value: offset, to: semesterStart) ?? semesterStart
        let parts = time.split(separator: ":").compactMap { Int($0) }
        return calendar.date(
            bySettingHour: parts.first ?? 8,
            minute: parts.dropFirst().first ?? 0,
            second: 0,
            of: day
        ) ?? day
    }

    private static func sectionDescription(start: String, end: String) -> String {
        guard !start.isEmpty else { return "" }
        return start == end || end.isEmpty ? "第\(start)节" : "第\(start)-\(end)节"
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func csvField(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func localStamp(_ date: Date) -> String {
        localDateTimeFormatter.string(from: date)
    }

    private static func utcStamp(_ date: Date) -> String {
        utcDateTimeFormatter.string(from: date)
    }

    private static let shanghaiTimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = shanghaiTimeZone
        return formatter
    }()

    private static let localDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.timeZone = shanghaiTimeZone
        return formatter
    }()

    private static let utcDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
