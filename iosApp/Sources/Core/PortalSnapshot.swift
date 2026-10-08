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
               ) != nil {
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
        guard let encoded = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]),
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
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
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
    /// Port of `PortalLogDetails.rowsFor`.
    static func rows(for nativeType: String, json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        switch nativeType {
        case "schedule":
            // A timetable is compared as ordered lesson labels per weekday.
            var rows: [String] = []
            for case let section as [String: Any] in (root["sections"] as? [[String: Any]] ?? []) where section["type"] as? String == "schedule" {
                for case let day as [String: Any] in (section["days"] as? [[String: Any]] ?? []) {
                    let dayName = day["name"] as? String ?? ""
                    for case let lesson as [String: Any] in (day["lessons"] as? [[String: Any]] ?? []) {
                        let title = lesson["title"] as? String ?? ""
                        let schedule = lesson["schedule"] as? [String: Any]
                        let weeks = schedule?["weeks"] as? String ?? ""
                        let location = schedule?["location"] as? String ?? ""
                        let teacher = schedule?["teacher"] as? String ?? ""
                        rows.append("\(dayName)|\(title)|\(weeks)|\(location)|\(teacher)")
                    }
                }
            }
            return rows
        case "grade", "exam", "program":
            var rows: [String] = []
            for case let section as [String: Any] in (root["sections"] as? [[String: Any]] ?? []) {
                if let tableRows = section["rows"] as? [[String]] {
                    rows.append(contentsOf: tableRows.map { $0.joined(separator: " | ") })
                }
                for case let card in (section["cards"] as? [[String: Any]] ?? []) {
                    let title = card["title"] as? String ?? ""
                    let subtitle = card["subtitle"] as? String ?? ""
                    let fields = (card["fields"] as? [[String: Any]] ?? [])
                        .map { "\($0["label"] as? String ?? ""):\($0["value"] as? String ?? "")" }
                        .joined(separator: " | ")
                    rows.append("\(title)|\(subtitle)|\(fields)")
                }
                for case let stat in (section["items"] as? [[String: Any]] ?? []) {
                    rows.append("\(stat["label"] as? String ?? ""):\(stat["value"] as? String ?? "")")
                }
            }
            return rows
        default:
            return []
        }
    }

    /// Port of `PortalLogDetails.describe`.
    static func describe(previousSnapshot: String?, currentRows: [String], changed: Bool) -> String {
        guard changed, let previousSnapshot else {
            return currentRows.isEmpty ? "未识别到数据" : "已建立初始数据"
        }
        guard let previousData = previousSnapshot.data(using: .utf8),
              let previousRoot = try? JSONSerialization.jsonObject(with: previousData) as? [String: Any] else {
            return "已更新"
        }
        let previousRows = rows(
            for: (previousRoot["type"] as? String) ?? "",
            json: previousSnapshot
        )
        let added = currentRows.filter { !previousRows.contains($0) }
        let removed = previousRows.filter { !currentRows.contains($0) }
        var parts: [String] = []
        if !added.isEmpty { parts.append("新增 \(added.count) 项") }
        if !removed.isEmpty { parts.append("移除 \(removed.count) 项") }
        return parts.isEmpty ? "内容更新" : parts.joined(separator: "，")
    }
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

    static func complete(schoolID: String, snapshots: [(item: PortalItem, json: String)]) {
        guard UserDefaults.standard.string(forKey: pendingSchoolKey) == schoolID else { return }
        // The caller's own count, not a fixed four. A school that declares a different number of
        // quick entries still gets its baseline recorded, and the log line reports what was actually
        // stored rather than a number that happens to match the usual four.
        guard !snapshots.isEmpty else { return }
        PortalPollHistory.append(PortalPollHistoryEntry(
            timestamp: Date(),
            status: "首次登录基线已建立（\(snapshots.count) 项）",
            notificationTriggered: false,
            details: snapshots.map { snapshot in
                PortalPollHistoryDetail(
                    category: category(for: snapshot.item.nativeType),
                    summary: "已建立初始数据",
                    difference: PortalLogDetails.describe(
                        previousSnapshot: nil,
                        currentRows: PortalLogDetails.rows(for: snapshot.item.nativeType ?? "", json: snapshot.json),
                        changed: false
                    )
                )
            }
        ))
        UserDefaults.standard.removeObject(forKey: pendingSchoolKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: preferencesKey)
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