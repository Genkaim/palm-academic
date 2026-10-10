import Foundation

/// Port of `PortalSnapshot` from `PortalSnapshot.kt`.
///
/// These helpers turn raw EAMS payloads into a canonical form so a server-side key reorder or a
/// volatile field such as the current teaching week cannot raise a false notification.
enum PortalSnapshot {
    /// Port of `PortalSnapshot.stableHash`.
    static func stableHash(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256Helper.hexDigest(normalized)
    }

    /// Port of `PortalSnapshot.visibleDocument`.
    static func visibleDocument(_ html: String) -> String {
        var value = html.replacingOccurrences(
            of: "(?is)<script[^>]*>.*?</script>", with: " ", options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: "(?is)<style[^>]*>.*?</style>", with: " ", options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: "(?is)<[^>]+>", with: " ", options: .regularExpression
        )
        value = value.replacingOccurrences(of: "&nbsp;", with: " ")
        return value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Port of `PortalSnapshot.hasCourseEntries`.
    static func hasCourseEntries(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || ["[]", "{}", "null"].contains(normalized) { return false }
        let lowercased = normalized.lowercased()
        if lowercased.contains("coursename") || lowercased.contains("lessonname") || lowercased.contains("courseid") {
            return true
        }
        if normalized.range(of: "\"lessonIds\"\\s*:\\s*\\[\\s*\\d", options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if normalized.range(of: "\"lessons\"\\s*:\\s*\\[\\s*\\{", options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if parseTables(normalized).contains(where: { !$0.rows.isEmpty }) { return true }
        // Different EAMS deployments wrap the same schedule under data/records/result/list keys.
        return normalized.range(
            of: "\"(?:data|records|rows|list|items|result|content)\"\\s*:\\s*\\[\\s*\\{",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    struct ParsedTable {
        let headers: [String]
        let rows: [[String]]
    }

    /// Port of `PortalSnapshot.parseTables`.
    static func parseTables(_ html: String, className: String? = nil) -> [ParsedTable] {
        let tablePattern = "(?is)<table\\b([^>]*)>(.*?)</table>"
        guard let tableRegex = try? NSRegularExpression(pattern: tablePattern) else { return [] }
        let fullRange = NSRange(html.startIndex..., in: html)
        return tableRegex.matches(in: html, range: fullRange).compactMap { match -> ParsedTable? in
            guard match.numberOfRanges >= 3,
                  let attributesRange = Range(match.range(at: 1), in: html),
                  let bodyRange = Range(match.range(at: 2), in: html) else { return nil }
            let attributes = String(html[attributesRange])
            if let className,
               attributes.range(
                   of: "class\\s*=\\s*[\"'][^\"']*\\b\(NSRegularExpression.escapedPattern(for: className))\\b[^\"']*[\"']",
                   options: [.regularExpression, .caseInsensitive]
               ) == nil {
                return nil
            }
            let body = String(html[bodyRange])
            guard let rowRegex = try? NSRegularExpression(pattern: "(?is)<tr\\b[^>]*>(.*?)</tr>") else { return nil }
            var parsedRows: [([String], Bool)] = []
            for rowMatch in rowRegex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard rowMatch.numberOfRanges >= 2,
                      let rowRange = Range(rowMatch.range(at: 1), in: body) else { continue }
                let rowHTML = String(body[rowRange])
                guard let cellRegex = try? NSRegularExpression(pattern: "(?is)<t[dh]\\b[^>]*>(.*?)</t[dh]>") else { continue }
                var cells: [String] = []
                for cellMatch in cellRegex.matches(in: rowHTML, range: NSRange(rowHTML.startIndex..., in: rowHTML)) {
                    guard cellMatch.numberOfRanges >= 2,
                          let cellRange = Range(cellMatch.range(at: 1), in: rowHTML) else { continue }
                    cells.append(visibleDocument(String(rowHTML[cellRange])))
                }
                let hasContent = cells.contains { !$0.isEmpty }
                let isHeaderRow = rowHTML.range(
                    of: "(?i)<th\\b", options: .regularExpression
                ) != nil
                if hasContent { parsedRows.append((cells, isHeaderRow)) }
            }
            guard !parsedRows.isEmpty else { return nil }
            let firstIsHeader = parsedRows[0].1 || looksLikeHeaderRow(parsedRows[0].0)
            return ParsedTable(
                headers: firstIsHeader ? parsedRows[0].0 : [],
                rows: parsedRows.dropFirst(firstIsHeader ? 1 : 0).map(\.0)
            )
        }
    }

    private static let headerTerms: Set<String> = [
        "课程", "课程名称", "课程代码", "学期", "学分", "绩点", "成绩", "成绩明细",
        "分项成绩明细", "总成绩明细", "考试时间", "考试地点", "地点", "座位号",
        "教师", "老师", "课程性质", "课程类别"
    ]

    /// Port of `PortalSnapshot.looksLikeHeaderRow`.
    private static func looksLikeHeaderRow(_ cells: [String]) -> Bool {
        guard !cells.isEmpty else { return false }
        let matches = cells.filter { cell in
            let normalized = cell
                .replacingOccurrences(of: "[：:\\s]+", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return headerTerms.contains(normalized)
        }.count
        return matches >= min(2, cells.count)
    }

    /// Port of `PortalSnapshot.tableRows`.
    static func tableRows(_ html: String, className: String? = nil) -> Set<String> {
        Set(parseTables(html, className: className).flatMap(\.rows).map { cells in
            let row = cells.joined(separator: " | ")
            guard !row.isEmpty,
                  !row.contains("课程名称"),
                  !row.contains("暂无"),
                  !row.contains("没有") else { return nil }
            return row
        }.compactMap { $0 })
    }

    static func parsedHTMLHasRows(_ html: String) -> Bool {
        parseTables(html).contains { !$0.rows.isEmpty }
    }

    static func materialPageHasData(_ json: String, nativeType: String) -> Bool {
        guard let page = MaterialPageParser.parse(json) else { return false }
        return QuickEntryBaseline.hasData(page: page, nativeType: nativeType)
    }

    static func historyDisplayContent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") || trimmed.range(of: "<html", options: .caseInsensitive) != nil {
            return parsedDataJSON(html: value, type: "legacy-html")
        }
        return value
    }

    /// Port of `PortalSnapshot.courseDataJson`.
    ///
    /// Only fields that can change the student's actual timetable survive. Volatile keys such as
    /// the current week and administrative metadata are dropped, and object keys and array
    /// elements are sorted so server-side ordering cannot create a false notification.
    static func courseDataJSON(payload: String, semesterId: String) -> String {
        let normalized = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = normalized.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return parsedDataJSON(html: payload, type: "course")
        }

        var result: [String: Any] = ["type": "course", "semesterId": semesterId]
        for key in root.keys.sorted() {
            guard let value = root[key] else { continue }
            let lower = key.lowercased()
            let normalizedKey = normalizeCourseKey(key)
            let sanitized = sanitizeCourseValue(value)
            guard !isIgnoredCourseKey(normalizedKey),
                  lower.contains("course") || lower.contains("lesson") || lower.contains("schedule"),
                  hasMeaningfulJSONValue(sanitized) else { continue }
            result[key] = sanitized
        }
        if result.count == 2 {
            // Keep the complete response when a school uses different field names; dropping it
            // here made a valid logged-in response look empty in the change log.
            result["payload"] = sanitizeCourseValue(root)
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: encoded, encoding: .utf8) else { return "{}" }
        return text
    }

    private static let volatileCourseKeys: Set<String> = [
        "currentweek", "currentweekindex", "currentteachingweek", "weekoftheterm"
    ]

    private static let nonScheduleCourseKeys: Set<String> = [
        "coursestdcount", "defaultopendepart", "mngtdepartment", "opendepartment",
        "scheduleassigndepartment", "lessonid2retake", "lessonid2seatnum", "lessonid2flag",
        "lesson2cultivatetypemap", "notattendlessonids", "nopublishlessonids",
        "timetablelayoutid", "totalretakecredits"
    ]

    private static func normalizeCourseKey(_ key: String) -> String {
        String(key.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func isIgnoredCourseKey(_ key: String) -> Bool {
        volatileCourseKeys.contains(key)
            || nonScheduleCourseKeys.contains(key)
            || key.contains("recruittype")
            || key == "department"
            || key.hasSuffix("department")
            || key.hasSuffix("depart")
    }

    private static func sanitizeCourseValue(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            var result: [String: Any] = [:]
            for key in dictionary.keys.sorted() {
                let normalizedKey = normalizeCourseKey(key)
                guard !isIgnoredCourseKey(normalizedKey), let child = dictionary[key] else { continue }
                result[key] = sanitizeCourseValue(child)
            }
            return result
        case let array as [Any]:
            return array.map(sanitizeCourseValue).sorted { canonicalSortKey($0) < canonicalSortKey($1) }
        default:
            return value
        }
    }

    private static func canonicalSortKey(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let string = value as? String { return string }
        // Mirrors Android's canonicalCourseSortKey, which uses plain toString() for everything
        // that is not an object/array. Serialising a bare scalar (NSNumber in e.g.
        // "lessonIds":[1,2,3]) WITHOUT .fragmentsAllowed makes NSJSONSerialization raise an
        // NSInvalidArgumentException -- an Obj-C exception Swift's `try?` cannot catch, which
        // aborted the app inside the background poll on schools whose JSON carries scalar arrays.
        if value is [Any] || value is [String: Any] {
            if let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .fragmentsAllowed]
            ),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        if let number = value as? NSNumber {
            // JSON booleans bridge to NSNumber; keep parity with Kotlin's Boolean.toString().
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        return String(describing: value)
    }

    private static func hasMeaningfulJSONValue(_ value: Any) -> Bool {
        switch value {
        case is NSNull: return false
        case let string as String: return !string.isEmpty
        case let array as [Any]: return !array.isEmpty
        case let dictionary as [String: Any]: return !dictionary.isEmpty
        default: return true
        }
    }

    /// Port of `PortalSnapshot.parsedDataJson`.
    static func parsedDataJSON(html: String, type: String, tableClass: String? = nil) -> String {
        let normalized = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("{") || normalized.hasPrefix("[") { return normalized }

        let requested = tableClass.map { parseTables(html, className: $0) } ?? []
        let tables = requested.isEmpty ? parseTables(html) : requested
        let object: [String: Any] = [
            "type": type,
            "tables": tables.map { ["headers": $0.headers, "rows": $0.rows] },
            "text": visibleDocument(html)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// Port of the change-description helpers in `PortalLogDetails.kt`.
enum PortalLogDetails {
    private static let courseTitleKeys: Set<String> = ["coursename", "lessonname", "coursefullname", "lessonfullname"]
    private static let courseCodeKeys: Set<String> = ["coursecode", "lessoncode", "code"]
    private static let courseIDKeys: Set<String> = ["lessonid", "courseid", "id"]
    private static let weekdayKeys: Set<String> = ["weekday", "dayofweek", "weekdays", "day"]
    private static let startSectionKeys: Set<String> = ["startunit", "startsection", "startperiod", "beginunit", "beginsection"]
    private static let endSectionKeys: Set<String> = ["endunit", "endsection", "endperiod", "finishunit", "finishsection"]
    private static let weekKeys: Set<String> = ["weeks", "weekindices", "weekindexes", "weeklist"]
    private static let roomKeys: Set<String> = ["room", "roomname", "classroom", "classroomname", "location", "place"]
    private static let teacherKeys: Set<String> = ["teacher", "teachers", "teachername", "teachernames", "instructor", "instructors"]
    private static let timeKeys: Set<String> = ["time", "coursetime", "scheduletime", "timeperiod"]

    static func rows(for nativeType: String, json: String) -> [String] {
        if nativeType == "schedule" {
            let rendered = materialRows(json, nativeType: nativeType)
            return rendered.isEmpty ? courseRows(json) : rendered
        }
        return materialRows(json, nativeType: nativeType)
    }

    static func courseRows(_ payload: String) -> [String] {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        // EAMS `course-table/get-data` nests the real course name under each lesson's `course`
        // object and puts the human schedule in `scheduleText`. Recognise that shape first; the
        // generic walker below does not know these keys and used to fall back to bare lesson IDs,
        // which never matched the rich rows the adapter rendered for the baseline.
        let eams = eamsGetDataRows(root)
        if !eams.isEmpty { return eams }
        var lessons: [[String: Any]] = []
        collectLessonObjects(root, parentKey: "", destination: &lessons)
        let formatted = normalizeRows(lessons.flatMap(formatLesson))
        if !formatted.isEmpty { return formatted }
        var lessonIDs: [String] = []
        collectValues(for: "lessonids", in: root, destination: &lessonIDs)
        return Array(Set(lessonIDs)).sorted().map { "课程 ID：\($0)" }
    }

    /// EAMS get-data: `lessons[].course.nameZh`, `lessons[].code` and
    /// `lessons[].scheduleText.dateTimePlacePersonText.text`. The latter already packs
    /// weeks/weekday/section/campus/room/teacher and may carry several segments separated by
    /// `;`/newlines. Rows are normalised to a stable form so repeated polls compare equal.
    private static func eamsGetDataRows(_ root: Any) -> [String] {
        guard let object = root as? [String: Any],
              let lessons = object["lessons"] as? [Any] else { return [] }
        var rows: [String] = []
        for case let lesson as [String: Any] in lessons {
            let course = lesson["course"] as? [String: Any]
            let title = nonEmpty(course?["nameZh"] as? String)
                ?? nonEmpty(course?["nameEn"] as? String)
                ?? nonEmpty(lesson["nameZh"] as? String)
            guard let title else { continue }
            let code = (lesson["code"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let base = courseName(title, code.isEmpty ? scalarText(lesson["id"]) : code)
            guard let text = (lesson["scheduleText"] as? [String: Any])
                .flatMap({ $0["dateTimePlacePersonText"] as? [String: Any] })
                .flatMap({ $0["text"] as? String })?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                rows.append(base)
                continue
            }
            let segments = text.components(separatedBy: CharacterSet(charactersIn: ";\u{ff1b}\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for segment in segments {
                let normalised = segment
                    .replacingOccurrences(of: "~", with: "-")
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                rows.append(trimSeparators("\(base)｜\(normalised)"))
            }
        }
        return normalizeRows(rows)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    static func materialRows(_ content: String, nativeType: String?) -> [String] {
        if let page = MaterialPageParser.parse(content), !page.sections.isEmpty {
            var result: [String] = []
            for section in page.sections {
                switch section {
                case .schedule(_, _, let days):
                    for day in days {
                        result.append(contentsOf: day.lessons.map { formatScheduleCard(day: day.name, card: $0) })
                    }
                case .cards(let title, let cards):
                    result.append(contentsOf: cards.map { formatCard(sectionTitle: title, card: $0, nativeType: nativeType) })
                case .table(let title, let headers, let rows):
                    result.append(contentsOf: rows.map { formatTableRow(title: title, headers: headers, row: $0) })
                case .stats(let title, let items):
                    for item in items where !item.label.isEmpty || !item.value.isEmpty {
                        result.append(trimSeparators("\(title)｜\(item.label)：\(item.value)"))
                    }
                case .fields(let title, let fields):
                    if !fields.isEmpty {
                        result.append(trimSeparators(([title] + fields.map { "\($0.label)：\($0.value)" })
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                            .joined(separator: "｜")))
                    }
                case .text(let title, let paragraphs):
                    result.append(contentsOf: paragraphs.filter { !$0.isEmpty }.map { trimSeparators("\(title)｜\($0)") })
                case .links:
                    break
                case .program(let title, let completed, let required, let modules):
                    var summary: [String] = []
                    if !completed.isEmpty { summary.append("已修学分：\(completed)") }
                    if !required.isEmpty { summary.append("要求学分：\(required)") }
                    if !summary.isEmpty { result.append(trimSeparators(([title] + summary).joined(separator: "｜"))) }
                    result.append(contentsOf: programRows(modules))
                }
            }
            let normalized = normalizeRows(result)
            if !normalized.isEmpty { return normalized }
        }

        guard let data = content.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tables = root["tables"] as? [[String: Any]] else { return [] }
        var result: [String] = []
        for table in tables {
            let headers = table["headers"] as? [String] ?? []
            for row in table["rows"] as? [[String]] ?? [] {
                result.append(formatTableRow(title: "", headers: headers, row: row))
            }
        }
        return normalizeRows(result)
    }

    static func encode(_ rows: [String]) -> String {
        let rows = normalizeRows(rows)
        guard let data = try? JSONSerialization.data(withJSONObject: rows),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    static func describe(previousSnapshot: String?, currentRows: [String], changed: Bool) -> String {
        let current = normalizeRows(currentRows)
        guard let previousSnapshot else { return currentData(current) }
        let previous = decode(previousSnapshot)
        guard changed else { return currentData(current) }
        let previousSet = Set(previous)
        let currentSet = Set(current)
        let added = current.filter { !previousSet.contains($0) }
        let removed = previous.filter { !currentSet.contains($0) }
        var parts: [String] = []
        if !added.isEmpty { parts.append("新增或变更后（\(added.count) 项）：\n" + bulletRows(added)) }
        if !removed.isEmpty { parts.append("移除或变更前（\(removed.count) 项）：\n" + bulletRows(removed)) }
        if parts.isEmpty {
            parts.append("业务快照发生变化，但已识别的展示字段一致。\n" + currentData(current))
        }
        return parts.joined(separator: "\n\n")
    }

    private static func currentData(_ rows: [String]) -> String {
        "当前数据（\(rows.count) 项）：\n" + (rows.isEmpty ? "• 暂无可展示的具体条目" : bulletRows(rows))
    }

    private static func bulletRows(_ rows: [String]) -> String { rows.map { "• \($0)" }.joined(separator: "\n") }

    private static func decode(_ value: String) -> [String] {
        guard let data = value.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return normalizeRows(rows)
    }

    private static func formatScheduleCard(day: String, card: MaterialCardItem) -> String {
        let details: [String]
        if let schedule = card.schedule {
            details = [
                day,
                sectionText(start: schedule.startSection, end: schedule.endSection),
                schedule.weeks.isEmpty ? nil : "第\(schedule.weeks)周",
                schedule.startTime.isEmpty ? nil : (schedule.endTime.isEmpty ? schedule.startTime : "\(schedule.startTime)-\(schedule.endTime)"),
                schedule.location.isEmpty ? nil : "地点：\(schedule.location)",
                schedule.teacher.isEmpty ? nil : "教师：\(schedule.teacher)"
            ].compactMap { $0 }
        } else {
            details = card.fields.compactMap { $0.value.isEmpty ? nil : "\($0.label)：\($0.value)" }
        }
        return trimSeparators(([courseName(card.title, card.subtitle)] + details).joined(separator: "｜"))
    }

    private static func formatCard(sectionTitle: String, card: MaterialCardItem, nativeType: String?) -> String {
        let accentLabel = nativeType == "grade" ? "成绩" : (nativeType == "exam" ? "状态" : "结果")
        var details: [String] = []
        if !sectionTitle.isEmpty { details.append(sectionTitle) }
        details.append(courseName(card.title, card.subtitle))
        if !card.accent.isEmpty { details.append("\(accentLabel)：\(card.accent)") }
        details.append(contentsOf: card.fields.compactMap { $0.value.isEmpty ? nil : "\($0.label)：\($0.value)" })
        return trimSeparators(details.joined(separator: "｜"))
    }

    private static func formatTableRow(title: String, headers: [String], row: [String]) -> String {
        let values = row.enumerated().compactMap { index, value -> String? in
            guard !value.isEmpty else { return nil }
            if headers.indices.contains(index), !headers[index].isEmpty { return "\(headers[index])：\(value)" }
            return value
        }
        return trimSeparators(([title] + values).joined(separator: "｜"))
    }

    private static func programRows(_ modules: [ProgramModule]) -> [String] {
        modules.flatMap { module in
            var result: [String] = []
            if !module.title.isEmpty || !module.requirements.isEmpty {
                result.append(trimSeparators(([module.title] + module.requirements).joined(separator: "｜")))
            }
            result.append(contentsOf: module.courses.map { formatTableRow(title: module.title, headers: module.headers, row: $0) })
            result.append(contentsOf: programRows(module.children))
            return result
        }
    }

    private static func formatLesson(_ lesson: [String: Any]) -> [String] {
        let title = directText(lesson, keys: courseTitleKeys)
        guard !title.isEmpty else { return [] }
        let code = directText(lesson, keys: courseCodeKeys)
        let identifier = directText(lesson, keys: courseIDKeys)
        let base = courseName(title, code.isEmpty ? identifier : code)
        var schedules: [[String: Any]] = []
        for (key, value) in lesson {
            let normalized = normalizeKey(key)
            if (normalized.contains("schedule") || normalized.contains("arrange")) && !normalized.contains("department") {
                collectScheduleObjects(value, destination: &schedules)
            }
        }
        if schedules.isEmpty, hasScheduleFields(lesson) { schedules.append(lesson) }
        if schedules.isEmpty { return [base] }
        return schedules.map { schedule in
            let details: [String?] = [
                formatWeekday(findValue(schedule, keys: weekdayKeys)),
                sectionText(start: findText(schedule, keys: startSectionKeys), end: findText(schedule, keys: endSectionKeys)),
                formatWeeks(findValue(schedule, keys: weekKeys)),
                optional(findText(schedule, keys: timeKeys)),
                optional(findText(schedule, keys: roomKeys)).map { "地点：\($0)" },
                optional(findNames(schedule, keys: teacherKeys)).map { "教师：\($0)" }
            ]
            return trimSeparators(([base] + details.compactMap { $0 }).joined(separator: "｜"))
        }
    }

    private static func collectLessonObjects(_ value: Any, parentKey: String, destination: inout [[String: Any]]) {
        if let object = value as? [String: Any] {
            if !directText(object, keys: courseTitleKeys).isEmpty { destination.append(object) }
            for (key, child) in object { collectLessonObjects(child, parentKey: normalizeKey(key), destination: &destination) }
        } else if let array = value as? [Any] {
            for child in array {
                if let object = child as? [String: Any],
                   (parentKey.contains("lesson") || parentKey.contains("course")),
                   !directText(object, keys: courseTitleKeys).isEmpty { destination.append(object) }
                collectLessonObjects(child, parentKey: parentKey, destination: &destination)
            }
        }
    }

    private static func collectScheduleObjects(_ value: Any, destination: inout [[String: Any]]) {
        if let object = value as? [String: Any] {
            if hasScheduleFields(object) { destination.append(object) }
            else { for child in object.values { collectScheduleObjects(child, destination: &destination) } }
        } else if let array = value as? [Any] {
            for child in array { collectScheduleObjects(child, destination: &destination) }
        }
    }

    private static func collectValues(for target: String, in value: Any, destination: inout [String]) {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                if normalizeKey(key) == target {
                    if let array = child as? [Any] { destination.append(contentsOf: array.map(scalarText).filter { !$0.isEmpty }) }
                    else if !scalarText(child).isEmpty { destination.append(scalarText(child)) }
                } else { collectValues(for: target, in: child, destination: &destination) }
            }
        } else if let array = value as? [Any] {
            for child in array { collectValues(for: target, in: child, destination: &destination) }
        }
    }

    private static func hasScheduleFields(_ object: [String: Any]) -> Bool {
        let keys = Set(object.keys.map(normalizeKey))
        return !keys.intersection(weekdayKeys.union(startSectionKeys).union(weekKeys).union(roomKeys)).isEmpty
    }

    private static func directText(_ object: [String: Any], keys: Set<String>) -> String {
        for (key, value) in object where keys.contains(normalizeKey(key)) { return scalarText(value) }
        return ""
    }

    private static func findValue(_ object: [String: Any], keys: Set<String>) -> Any? {
        for (key, value) in object where keys.contains(normalizeKey(key)) { return value }
        return nil
    }

    private static func findText(_ object: [String: Any], keys: Set<String>) -> String { scalarText(findValue(object, keys: keys)) }

    private static func findNames(_ object: [String: Any], keys: Set<String>) -> String {
        guard let value = findValue(object, keys: keys) else { return "" }
        return Array(Set(extractNames(value))).joined(separator: "/")
    }

    private static func extractNames(_ value: Any) -> [String] {
        if let text = value as? String { return optional(text).map { [$0] } ?? [] }
        if let number = value as? NSNumber { return [number.stringValue] }
        if let object = value as? [String: Any] {
            let direct = directText(object, keys: ["name", "teachername", "fullname"])
            return direct.isEmpty ? object.values.flatMap(extractNames) : [direct]
        }
        if let array = value as? [Any] { return array.flatMap(extractNames) }
        return []
    }

    private static func formatWeekday(_ value: Any?) -> String? {
        let text = scalarText(value)
        guard !text.isEmpty else { return nil }
        if let number = Int(text), (1...7).contains(number) {
            return ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"][number - 1]
        }
        return text
    }

    private static func sectionText(start: String, end: String) -> String? {
        guard !start.isEmpty || !end.isEmpty else { return nil }
        let range = start.isEmpty ? end : (end.isEmpty || start == end ? start : "\(start)-\(end)")
        return "第\(range)节"
    }

    private static func formatWeeks(_ value: Any?) -> String? {
        guard let value else { return nil }
        let numbers = (value as? [Any] ?? []).compactMap { Int(scalarText($0)) }.sorted()
        if numbers.isEmpty { return optional(scalarText(value)).map { "第\($0)周" } }
        var ranges: [String] = []
        var start = numbers[0], end = numbers[0]
        for week in numbers.dropFirst() {
            if week == end + 1 { end = week }
            else { ranges.append(start == end ? "\(start)" : "\(start)-\(end)"); start = week; end = week }
        }
        ranges.append(start == end ? "\(start)" : "\(start)-\(end)")
        return "第\(ranges.joined(separator: "、"))周"
    }

    private static func courseName(_ title: String, _ code: String) -> String {
        code.isEmpty || code == title ? title : "\(title)（\(code)）"
    }

    private static func scalarText(_ value: Any?) -> String {
        if value == nil || value is NSNull { return "" }
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func normalizeRows(_ rows: [String]) -> [String] {
        Array(Set(rows.map { trimSeparators($0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)) }
            .filter { !$0.isEmpty })).sorted()
    }

    private static func trimSeparators(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "｜· ：").union(.whitespacesAndNewlines))
    }

    private static func normalizeKey(_ value: String) -> String {
        String(value.filter { $0.isLetter || $0.isNumber }).lowercased()
    }

    private static func optional(_ value: String) -> String? { value.isEmpty ? nil : value }
}

/// Port of `QuickEntryBaseline.kt`.
enum QuickEntryBaseline {
    private static let preferencesKey = "quick_entry_baseline"
    private static let pendingSchoolKey = "pending_school"

    static func request(schoolID: String) {
        UserDefaults.standard.set(schoolID, forKey: pendingSchoolKey)
    }

    static func isPending(schoolID: String) -> Bool {
        UserDefaults.standard.string(forKey: pendingSchoolKey) == schoolID
    }

    static func complete(
        schoolID: String,
        snapshots: [(item: PortalItem, json: String)],
        expectedCount: Int
    ) {
        let pendingSchool = UserDefaults.standard.string(forKey: pendingSchoolKey)
        guard pendingSchool == schoolID else {
            NSLog(
                "PalmAcademic/baseline: complete ignored, pending school %@ != %@",
                pendingSchool ?? "(nil)", schoolID
            )
            return
        }
        // Android completes this warm-up only after every declared native entry has published real
        // data. A partial cache must stay pending, otherwise the missing page can be mistaken for
        // a legitimate empty baseline by the first background comparison.
        guard expectedCount > 0, snapshots.count == expectedCount else {
            NSLog("PalmAcademic/baseline: complete ignored, only %d/%d snapshots", snapshots.count, expectedCount)
            return
        }
        // Seed the exact business keys read by PortalPollWorker. Earlier builds only wrote a log
        // saying that a baseline existed; the first background run still found nil and silently
        // established a second baseline. Persisting the normalized rows here makes the first
        // scheduled comparison a real comparison, including a legitimate empty initial state.
        let defaults = UserDefaults.standard
        for snapshot in snapshots {
            guard let nativeType = snapshot.item.nativeType else { continue }
            let rows = PortalLogDetails.rows(for: nativeType, json: snapshot.json)
            let encoded = PortalLogDetails.encode(rows)
            defaults.set(snapshot.json, forKey: "snapshot_\(nativeType)")
            switch nativeType {
            case "schedule":
                defaults.set(encoded, forKey: "course_business_snapshot_v1")
                defaults.set(!rows.isEmpty, forKey: "course_has_entries")
            case "grade":
                defaults.set(encoded, forKey: "grade_business_snapshot_v1")
            case "exam":
                defaults.set(encoded, forKey: "exam_business_snapshot_v1")
            default:
                break
            }
        }

        NSLog("PalmAcademic/baseline: recording %d-item initial baseline history entry", expectedCount)
        PortalPollHistory.append(PortalPollHistoryEntry(
            timestamp: Date(),
            status: "首次登录基线已建立（\(expectedCount) 项）",
            notificationTriggered: false,
            details: snapshots.map { snapshot in
                let rows = PortalLogDetails.rows(
                    for: snapshot.item.nativeType ?? "",
                    json: snapshot.json
                )
                return PortalPollHistoryDetail(
                    category: category(for: snapshot.item.nativeType),
                    summary: "已建立初始数据",
                    difference: PortalLogDetails.describe(
                        previousSnapshot: nil,
                        currentRows: rows,
                        changed: false
                    ),
                    previousContent: nil,
                    currentContent: PortalLogDetails.encode(rows)
                )
            }
        ))
        UserDefaults.standard.removeObject(forKey: pendingSchoolKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: preferencesKey)
        Task { @MainActor in
            PortalBackgroundScheduler.runAfterBaselineEstablished()
        }
    }

    static func category(for nativeType: String?) -> String {
        switch nativeType {
        case "schedule": return "课表"
        case "grade": return "成绩"
        case "exam": return "考试"
        case "program": return "培养方案"
        default: return "快捷入口"
        }
    }

    /// Port of `quickBaselineHasData`: distinguishes a populated page from its DOM skeleton.
    static func hasData(page: MaterialPage, nativeType: String?) -> Bool {
        switch nativeType {
        case "schedule":
            for section in page.sections {
                if case .schedule(_, _, let days) = section, days.contains(where: { !$0.lessons.isEmpty }) {
                    return true
                }
            }
            return false
        case "grade":
            for section in page.sections {
                switch section {
                case .cards(_, let cards) where !cards.isEmpty: return true
                case .table(_, _, let rows) where !rows.isEmpty: return true
                case .stats(_, let items) where items.contains(where: {
                    !$0.value.trimmingCharacters(in: .whitespaces).isEmpty && $0.value != "--"
                }): return true
                default: continue
                }
            }
            return false
        case "exam":
            for section in page.sections {
                switch section {
                case .cards(_, let cards) where !cards.isEmpty: return true
                case .table(_, _, let rows) where !rows.isEmpty: return true
                default: continue
                }
            }
            return false
        case "program":
            for section in page.sections {
                if case .program(_, let completed, let required, let modules) = section,
                   !completed.isEmpty || !required.isEmpty || modules.contains(where: { $0.hasData() }) {
                    return true
                }
            }
            return false
        default:
            return !page.sections.isEmpty
        }
    }

    /// Port of `orderedQuickBaselineItems`.
    static func orderedQuickBaselineItems(_ items: [PortalItem]) -> [PortalItem] {
        ["schedule", "grade", "exam", "program"].compactMap { type in
            items.first { $0.quick == true && $0.nativeType == type }
        }
    }
}
