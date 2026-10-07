import BackgroundTasks
import Foundation
import UserNotifications

/// Port of `PortalPollWorker` from `PortalPollWorker.kt`.
///
/// The Android worker runs under WorkManager; iOS uses `BGAppRefreshTask` with the same cadence
/// clamping, the same snapshot comparison rules and the same change-history records.
///
/// Main-actor isolated because it reads `NotificationPreferences` and the snapshot
/// store, both of which are ObservableObjects driven from the settings UI. This
/// matches Android, where the worker reads the same SharedPreferences-backed flags
/// before doing any I/O.
@MainActor
final class PortalPollWorker {
    static let shared = PortalPollWorker()

    private let auth = AuthRepository()

    private init() {}

    /// Port of `PortalPollWorker.doWork`.
    @discardableResult
    func run() async -> Bool {
        let preferences = NotificationPreferences.shared
        guard preferences.monitorEnabled, preferences.anyEnabled else { return false }

        let checkedAt = Date()
        var details: [PortalPollHistoryDetail] = []

        func finish(_ status: String) {
            PortalPollHistory.append(PortalPollHistoryEntry(
                timestamp: checkedAt,
                status: status,
                notificationTriggered: details.contains(where: \.notificationTriggered),
                details: details
            ))
        }

        guard PortalHTTP.hasSessionCookie else {
            let notified = await notifyAuthenticationFailure()
            details.append(PortalPollHistoryDetail(
                category: "登录状态",
                summary: "登录 Cookie 不存在",
                notificationTriggered: notified,
                technicalDetails: "PortalHTTP.hasSessionCookie 返回 false。"
            ))
            finish("登录已过期")
            return false
        }

        guard let school = SchoolCatalog.shared.loadDefinition() else {
            details.append(PortalPollHistoryDetail(
                category: "学校配置",
                summary: "学校定义不可用",
                technicalDetails: SchoolCatalog.shared.loadError ?? "无法读取学校定义。"
            ))
            finish("检查完成（配置不可用）")
            return false
        }

        let monitor = school.resolvedMonitor
        let scheduleEnabled = preferences.scheduleEnabled
        let gradeEnabled = preferences.gradeEnabled
        let examEnabled = preferences.examEnabled

        // The course table page is the single entry point that carries both the semester id and the
        // student id, so it is fetched first even when only grades or exams are watched.
        let coursePageURL = monitor.url(baseURL: school.baseUrl, path: monitor.coursePagePath)
        let coursePage = await get(coursePageURL)

        if coursePage.isAuthenticationFailure {
            let notified = await notifyAuthenticationFailure()
            details.append(coursePage.historyDetail(category: "课表", summary: "登录状态失效"))
            details.append(PortalPollHistoryDetail(
                category: "登录状态",
                summary: "课表页面返回登录页或未授权状态",
                notificationTriggered: notified
            ))
            finish("登录已过期")
            return false
        }
        guard coursePage.isSuccessful else {
            details.append(coursePage.historyDetail(category: "课表", summary: "请求失败"))
            finish("检查完成（入口暂不可用）")
            return false
        }

        let semesterId = extractSemesterId(from: coursePage.body, patterns: monitor.semesterIdPatterns)
        let studentId = extractStudentId(from: coursePage.finalURL + "\n" + coursePage.body, patterns: monitor.studentIdPatterns)

        if requiresSemesterId(monitor, schedule: scheduleEnabled, grade: gradeEnabled, exam: examEnabled), semesterId == nil {
            details.append(coursePage.historyDetail(
                category: "课表",
                summary: "未识别当前学期",
                technicalDetails: "学校定义中的 semesterIdPatterns 未匹配页面内容。"
            ))
            finish("检查完成（规则未匹配）")
            return false
        }
        if requiresStudentId(monitor, schedule: scheduleEnabled, grade: gradeEnabled, exam: examEnabled), studentId == nil {
            details.append(coursePage.historyDetail(
                category: "课表",
                summary: "未识别学生 ID",
                technicalDetails: "学校规则与通用学号规则均未匹配入口最终地址或页面内容。"
            ))
            finish("检查完成（规则未匹配）")
            return false
        }

        let semester = semesterId ?? ""
        let student = studentId ?? ""
        var notifiedAny = false

        if scheduleEnabled {
            let url = monitor.courseDataURL(baseURL: school.baseUrl, semesterId: semester, studentId: student)
            let response = await get(url)
            if response.isAuthenticationFailure {
                let notified = await notifyAuthenticationFailure()
                details.append(response.historyDetail(category: "课表", summary: "登录状态失效"))
                details.append(PortalPollHistoryDetail(
                    category: "登录状态",
                    summary: "课表数据返回登录页或未授权状态",
                    notificationTriggered: notified
                ))
                finish("登录已过期")
                return false
            }
            guard response.isSuccessful else {
                details.append(response.historyDetail(category: "课表", summary: "请求失败"))
                finish("检查完成（课表暂不可用）")
                return false
            }
            let canonical = PortalSnapshot.courseDataJSON(payload: response.body, semesterId: semester)
            let comparison = compareAndStore(canonical: canonical, nativeType: "schedule")
            details.append(comparison.detail)
            notifiedAny = notifiedAny || comparison.detail.notificationTriggered
        }

        if gradeEnabled {
            let url = monitor.gradeDataURL(baseURL: school.baseUrl, semesterId: semester, studentId: student)
            let response = await get(url)
            if response.isSuccessful {
                let canonical = gradeOrExamSnapshot(body: response.body, type: "grade")
                let comparison = compareAndStore(canonical: canonical, nativeType: "grade")
                details.append(comparison.detail)
                notifiedAny = notifiedAny || comparison.detail.notificationTriggered
            } else {
                details.append(response.historyDetail(category: "成绩", summary: "请求失败"))
            }
        }

        if examEnabled {
            let url = monitor.examDataURL(baseURL: school.baseUrl, semesterId: semester, studentId: student)
            let response = await get(url)
            if response.isSuccessful {
                let canonical = gradeOrExamSnapshot(body: response.body, type: "exam")
                let comparison = compareAndStore(canonical: canonical, nativeType: "exam")
                details.append(comparison.detail)
                notifiedAny = notifiedAny || comparison.detail.notificationTriggered
            } else {
                details.append(response.historyDetail(category: "考试", summary: "请求失败"))
            }
        }

        finish(notifiedAny ? "检测到教务信息变更" : "检查完成（无变化）")
        return notifiedAny
    }

    // MARK: - Snapshot comparison

    private struct ComparisonResult {
        let detail: PortalPollHistoryDetail
    }

    private func gradeOrExamSnapshot(body: String, type: String) -> String {
        let normalized = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("{") || normalized.hasPrefix("[") {
            var text = PortalSnapshot.parsedDataJSON(html: body, type: type)
            // Carry the type so `describe` can re-read the rows from the stored snapshot.
            if var object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                object["type"] = type
                if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
                   let updated = String(data: data, encoding: .utf8) {
                    text = updated
                }
            }
            return text
        }
        return PortalSnapshot.parsedDataJSON(html: body, type: type)
    }

    /// Compares the canonical payload against the stored snapshot and raises a notification only
    /// when the student-visible content actually changed.
    private func compareAndStore(canonical: String, nativeType: String) -> ComparisonResult {
        let preferences = NotificationPreferences.shared
        let previous = preferences.snapshot(for: nativeType)

        // The first successful observation establishes a baseline and must stay silent.
        guard let previous else {
            preferences.storeSnapshot(canonical, for: nativeType)
            return ComparisonResult(detail: PortalPollHistoryDetail(
                category: QuickEntryBaseline.category(for: nativeType),
                summary: "已建立初始基线"
            ))
        }

        let previousHash = PortalSnapshot.stableHash(previous)
        let currentHash = PortalSnapshot.stableHash(canonical)
        guard previousHash != currentHash else {
            return ComparisonResult(detail: PortalPollHistoryDetail(
                category: QuickEntryBaseline.category(for: nativeType),
                summary: "无变化"
            ))
        }

        let currentRows = PortalLogDetails.rows(for: nativeType, json: canonical)
        let previousRows = PortalLogDetails.rows(for: nativeType, json: previous)
        let changed = currentRows != previousRows
        let difference = PortalLogDetails.describe(
            previousSnapshot: previous,
            currentRows: currentRows,
            changed: changed
        )
        preferences.storeSnapshot(canonical, for: nativeType)

        // A payload that lost its data (server returned an empty shell) is not a real change.
        guard !currentRows.isEmpty else {
            return ComparisonResult(detail: PortalPollHistoryDetail(
                category: QuickEntryBaseline.category(for: nativeType),
                summary: "内容为空，未推送",
                changed: false,
                difference: difference
            ))
        }

        let notified = postChangeNotification(
            category: QuickEntryBaseline.category(for: nativeType),
            summary: difference
        )
        return ComparisonResult(detail: PortalPollHistoryDetail(
            category: QuickEntryBaseline.category(for: nativeType),
            summary: changed ? "内容有更新" : "响应内容变化",
            changed: changed,
            notificationTriggered: notified,
            difference: difference
        ))
    }

    // MARK: - Notifications

    private func notifyAuthenticationFailure() async -> Bool {
        let preferences = NotificationPreferences.shared
        let shouldNotify = preferences.shouldNotifyAuthenticationFailure()
        guard shouldNotify else { return false }
        let content = UNMutableNotificationContent()
        content.title = "登录已过期"
        content.body = "掌上教务需要重新登录教务系统"
        content.sound = .default
        content.categoryIdentifier = PortalMonitor.notificationCategory
        let request = UNNotificationRequest(
            identifier: "portal_auth_failure",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
        return true
    }

    private func postChangeNotification(category: String, summary: String) -> Bool {
        let content = UNMutableNotificationContent()
        content.title = "\(category)有更新"
        content.body = summary
        content.sound = .default
        content.categoryIdentifier = PortalMonitor.notificationCategory
        content.userInfo = ["source": "portal_change"]
        let request = UNNotificationRequest(
            identifier: "portal_change_\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        return true
    }

    // MARK: - Networking

    private struct Response {
        let body: String
        let finalURL: String
        let statusCode: Int

        var isSuccessful: Bool { (200..<400).contains(statusCode) }

        /// Login-page detection goes through `AuthRepository`, which is main-actor isolated.
        @MainActor
        var isAuthenticationFailure: Bool {
            AuthRepository.isLoginPage(body, finalURL: finalURL)
                || statusCode == 401 || statusCode == 403
        }

        func historyDetail(
            category: String,
            summary: String,
            notificationTriggered: Bool = false,
            technicalDetails: String? = nil
        ) -> PortalPollHistoryDetail {
            PortalPollHistoryDetail(
                category: category,
                summary: summary,
                notificationTriggered: notificationTriggered,
                technicalDetails: technicalDetails ?? "HTTP \(statusCode) · \(finalURL)"
            )
        }
    }

    private func get(_ urlString: String) async -> Response {
        guard let url = URL(string: urlString) else {
            return Response(body: "", finalURL: urlString, statusCode: -1)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let (data, response) = try await PortalHTTP.session.data(for: request)
            let http = response as? HTTPURLResponse
            let body = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: String.Encoding.utf8)
                ?? ""
            return Response(
                body: body,
                finalURL: http?.url?.absoluteString ?? urlString,
                statusCode: http?.statusCode ?? -1
            )
        } catch {
            return Response(body: "", finalURL: urlString, statusCode: -1)
        }
    }

    // MARK: - Identifier extraction

    /// Port of `PortalMonitorDefinition.extractSemesterId`, including the `allSemesters` select
    /// fast path that picks the newest labelled option.
    func extractSemesterId(from page: String, patterns: [String]) -> String? {
        if let fromSelect = extractLatestSemesterOption(page) { return fromSelect }
        for pattern in patterns {
            if let value = firstCapture(pattern, in: page), !value.isEmpty { return value }
        }
        return nil
    }

    /// Port of `PortalMonitorDefinition.extractStudentId`, including the neutral fallbacks that
    /// keep header-only "姓名(学号)" deployments working.
    func extractStudentId(from page: String, patterns: [String]) -> String? {
        let generic = [
            "(?:学号|学生号|student(?:Id|No)?)\\s*[：:=]?\\s*(\\d{6,20})",
            "[（(]\\s*(\\d{6,20})\\s*[）)]"
        ]
        for pattern in patterns + generic {
            if let value = firstCapture(pattern, in: page), !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return value
            }
        }
        return nil
    }

    private func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return nil }
        let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        guard let match, match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func extractLatestSemesterOption(_ page: String) -> String? {
        guard let selectRegex = try? NSRegularExpression(
            pattern: "(?is)<select\\b(?=[^>]*\\bid\\s*=\\s*[\"']allSemesters[\"'])[^>]*>(.*?)</select>"
        ),
            let selectMatch = selectRegex.firstMatch(in: page, range: NSRange(page.startIndex..., in: page)),
            selectMatch.numberOfRanges >= 2,
            let selectRange = Range(selectMatch.range(at: 1), in: page) else { return nil }

        let body = String(page[selectRange])
        guard let optionRegex = try? NSRegularExpression(pattern: "(?is)<option\\b([^>]*)>(.*?)</option>"),
              let valueRegex = try? NSRegularExpression(pattern: "(?i)\\bvalue\\s*=\\s*[\"']([^\"']+)[\"']") else {
            return nil
        }

        var best: (value: String, order: Int64)?
        for match in optionRegex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard match.numberOfRanges >= 3,
                  let attributesRange = Range(match.range(at: 1), in: body),
                  let labelRange = Range(match.range(at: 2), in: body) else { continue }
            let attributes = String(body[attributesRange])
            guard let valueMatch = valueRegex.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)),
                  valueMatch.numberOfRanges >= 2,
                  let valueRange = Range(valueMatch.range(at: 1), in: attributes) else { continue }
            let value = String(attributes[valueRange]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            let label = String(body[labelRange])
                .replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)

            let season: Int64 = label.contains("春") ? 2 : (label.contains("秋") ? 1 : 0)
            var order: Int64 = Int64.min
            if let years = firstCapture("(\\d{4})\\s*[-—]\\s*(\\d{4})", in: label),
               let startYear = Int64(years) {
                order = startYear * 10 + season
            } else if let numeric = Int64(value) {
                order = numeric
            }
            if best == nil || order > best!.order {
                best = (value, order)
            }
        }
        return best?.value
    }

    private func requiresSemesterId(_ monitor: PortalMonitorDefinition, schedule: Bool, grade: Bool, exam: Bool) -> Bool {
        (schedule && monitor.courseDataPathTemplate.contains("{semesterId}"))
            || (grade && monitor.gradeDataPathTemplate.contains("{semesterId}"))
            || (exam && monitor.examDataPathTemplate.contains("{semesterId}"))
    }

    private func requiresStudentId(_ monitor: PortalMonitorDefinition, schedule: Bool, grade: Bool, exam: Bool) -> Bool {
        (schedule && monitor.courseDataPathTemplate.contains("{studentId}"))
            || (grade && monitor.gradeDataPathTemplate.contains("{studentId}"))
            || (exam && monitor.examDataPathTemplate.contains("{studentId}"))
    }
}

/// Registers the background refresh handler. Mirrors `PortalMonitor.restore`.
@MainActor
enum PortalBackgroundScheduler {
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: PortalMonitor.refreshTaskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // Always chain the next request first: the system drops the task when the handler
            // returns without scheduling a successor.
            let preferences = NotificationPreferences.shared
            if preferences.monitorEnabled {
                PortalMonitor.shared.schedule(intervalMinutes: preferences.intervalMinutes)
            }
            let work = Task {
                await PortalPollWorker.shared.run()
                refreshTask.setTaskCompleted(success: true)
            }
            refreshTask.expirationHandler = {
                work.cancel()
                refreshTask.setTaskCompleted(success: false)
            }
        }
    }
}