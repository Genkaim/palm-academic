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
    func run(manual: Bool = false) async -> Bool {
        let preferences = NotificationPreferences.shared
        guard (manual || preferences.monitorEnabled), preferences.anyEnabled else { return false }

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
        var partiallyUnavailable = false

        if scheduleEnabled {
            let url = monitor.courseDataURL(baseURL: school.baseUrl, semesterId: semester, studentId: student)
            let response = await get(url, referer: coursePage.finalURL, ajax: true)
            if response.isAuthenticationFailure {
                let notified = await notifyAuthenticationFailure()
                details.append(response.historyDetail(category: "课表", summary: "登录状态失效"))
                details.append(authenticationDetail(notified: notified, reason: "课表数据接口返回登录页或未授权状态"))
                finish("登录已过期")
                return false
            }
            if !response.isSuccessful {
                details.append(response.historyDetail(category: "课表", summary: "请求失败"))
                partiallyUnavailable = true
            } else if response.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                details.append(response.historyDetail(
                    category: "课表",
                    summary: "响应格式无法识别",
                    technicalDetails: "课表数据响应为空。"
                ))
                partiallyUnavailable = true
            } else {
                let rendered = renderedSnapshotOrResponse(school: school, nativeType: "schedule", responseBody: response.body)
                details.append(await updateCourseSnapshot(semesterID: semester, response: response, renderedContent: rendered))
            }
        }

        if gradeEnabled {
            let url = monitor.gradeDataURL(baseURL: school.baseUrl, semesterId: semester, studentId: student)
            let response = await getNativePage(
                school: school,
                nativeType: "grade",
                dataURL: url,
                initialReferer: coursePage.finalURL
            )
            if response.isAuthenticationFailure {
                let notified = await notifyAuthenticationFailure()
                details.append(response.historyDetail(category: "成绩", summary: "登录状态失效"))
                details.append(authenticationDetail(notified: notified, reason: "成绩页面返回登录页或未授权状态"))
                finish("登录已过期")
                return false
            } else if !response.isSuccessful {
                details.append(response.historyDetail(category: "成绩", summary: "请求失败"))
                partiallyUnavailable = true
            } else {
                let parsed = renderedSnapshotOrResponse(school: school, nativeType: "grade", responseBody: response.body)
                details.append(await updateContentSnapshot(nativeType: "grade", response: response, parsedContent: parsed))
            }
        }

        if examEnabled {
            let url = monitor.examDataURL(baseURL: school.baseUrl, semesterId: semester, studentId: student)
            let response = await getNativePage(
                school: school,
                nativeType: "exam",
                dataURL: url,
                initialReferer: coursePage.finalURL
            )
            if response.isAuthenticationFailure {
                let notified = await notifyAuthenticationFailure()
                details.append(response.historyDetail(category: "考试", summary: "登录状态失效"))
                details.append(authenticationDetail(notified: notified, reason: "考试页面返回登录页或未授权状态"))
                finish("登录已过期")
                return false
            } else if !response.isSuccessful {
                details.append(response.historyDetail(category: "考试", summary: "请求失败"))
                partiallyUnavailable = true
            } else {
                let parsed = renderedSnapshotOrResponse(school: school, nativeType: "exam", responseBody: response.body)
                let tableRows = PortalSnapshot.tableRows(response.body)
                if tableRows.isEmpty,
                   PortalSnapshot.visibleDocument(response.body).isEmpty,
                   !PortalSnapshot.materialPageHasData(parsed, nativeType: "exam") {
                    details.append(response.historyDetail(
                        category: "考试",
                        summary: "未识别到考试内容",
                        technicalDetails: "响应为空，未更新考试基线。"
                    ))
                    partiallyUnavailable = true
                } else {
                    details.append(await updateContentSnapshot(
                        nativeType: "exam",
                        response: response,
                        parsedContent: parsed,
                        fallbackRows: tableRows.sorted()
                    ))
                }
            }
        }

        preferences.clearAuthenticationFailureMarker()
        UserDefaults.standard.set(Date(), forKey: "last_checked")
        finish(partiallyUnavailable ? "检查完成（部分项目不可用）" : "检查完成")
        return details.contains(where: \.notificationTriggered)
    }

    // MARK: - Snapshot comparison

    private func renderedSnapshotOrResponse(school: SchoolDefinition, nativeType: String, responseBody: String) -> String {
        let responseSnapshot = PortalSnapshot.parsedDataJSON(html: responseBody, type: nativeType)
        if PortalSnapshot.parsedHTMLHasRows(responseBody) { return responseSnapshot }
        guard let item = school.quickItems.first(where: { $0.nativeType == nativeType }) else { return responseSnapshot }
        let url = item.url(baseURL: school.baseUrl)
        guard let cached = MaterialPageCache.loadRaw(url: url),
              PortalSnapshot.materialPageHasData(cached, nativeType: nativeType) else { return responseSnapshot }
        return PortalSnapshot.historyDisplayContent(cached)
    }

    private func updateCourseSnapshot(semesterID: String, response: Response, renderedContent: String) async -> PortalPollHistoryDetail {
        let defaults = UserDefaults.standard
        let parsed = PortalSnapshot.courseDataJSON(payload: response.body, semesterId: semesterID)
        let rawRows = PortalLogDetails.courseRows(response.body)
        let currentRows = rawRows.isEmpty ? PortalLogDetails.materialRows(renderedContent, nativeType: "schedule") : rawRows
        let snapshot = currentRows.isEmpty
            ? "fallback:\(PortalSnapshot.stableHash(parsed))"
            : PortalLogDetails.encode(currentRows)
        let key = "course_business_snapshot_v1"
        let previous = defaults.string(forKey: key)
        let oldSemester = defaults.string(forKey: "course_business_semester_id_v1")
        let hasEntries = PortalSnapshot.hasCourseEntries(response.body)
        let changed = previous != nil
            && (previous != snapshot || (oldSemester != nil && oldSemester != semesterID && hasEntries))
        defaults.set(snapshot, forKey: key)
        defaults.set(semesterID, forKey: "course_business_semester_id_v1")
        defaults.set(hasEntries, forKey: "course_has_entries")
        ["course_hash", "course_semester_id", "course_semantic_hash_v3", "course_semantic_semester_id_v3", "course_parsed_json_v2", "course_raw_v1"]
            .forEach { defaults.removeObject(forKey: $0) }
        let notified = changed && NotificationPreferences.shared.scheduleEnabled
            ? await postChangeNotification(category: "课表", summary: "检测到课表新增或课程安排发生变化，请及时查看。")
            : false
        return PortalPollHistoryDetail(
            category: "课表",
            summary: previous == nil ? "已建立初始数据" : (changed ? "检测到变动" : "无变化"),
            changed: changed,
            notificationTriggered: notified,
            difference: PortalLogDetails.describe(
                previousSnapshot: previous?.hasPrefix("[") == true ? previous : nil,
                currentRows: currentRows,
                changed: changed
            ),
            notificationEnabled: NotificationPreferences.shared.scheduleEnabled,
            responseCode: response.statusCode,
            requestURL: response.requestURL,
            finalURL: response.finalURL,
            previousContent: previous,
            currentContent: snapshot
        )
    }

    private func updateContentSnapshot(
        nativeType: String,
        response: Response,
        parsedContent: String,
        fallbackRows: [String] = []
    ) async -> PortalPollHistoryDetail {
        let defaults = UserDefaults.standard
        let materialRows = PortalLogDetails.materialRows(parsedContent, nativeType: nativeType)
        let currentRows = materialRows.isEmpty ? fallbackRows : materialRows
        let snapshot = currentRows.isEmpty
            ? "fallback:\(PortalSnapshot.stableHash(parsedContent))"
            : PortalLogDetails.encode(currentRows)
        let key = "\(nativeType)_business_snapshot_v1"
        let previous = defaults.string(forKey: key)
        let changed = previous != nil && previous != snapshot
        defaults.set(snapshot, forKey: key)
        let legacyKeys = nativeType == "grade"
            ? ["grade_hash", "grade_parsed_json_v2", "grade_raw_v1"]
            : ["exam_rows", "exam_rows_v2", "exam_parsed_json_v2", "exam_raw_v1"]
        legacyKeys.forEach { defaults.removeObject(forKey: $0) }
        let enabled = nativeType == "grade"
            ? NotificationPreferences.shared.gradeEnabled
            : NotificationPreferences.shared.examEnabled
        let category = QuickEntryBaseline.category(for: nativeType)
        let message = nativeType == "grade"
            ? "检测到课程成绩新增或已有成绩发生变化，请及时查看。"
            : "检测到考试新增或已有考试安排发生变化，请及时查看。"
        let notified = changed && enabled
            ? await postChangeNotification(category: category, summary: message)
            : false
        return PortalPollHistoryDetail(
            category: category,
            summary: previous == nil ? "已建立初始数据" : (changed ? "检测到变动" : "无变化"),
            changed: changed,
            notificationTriggered: notified,
            difference: PortalLogDetails.describe(
                previousSnapshot: previous?.hasPrefix("[") == true ? previous : nil,
                currentRows: currentRows,
                changed: changed
            ),
            notificationEnabled: enabled,
            responseCode: response.statusCode,
            requestURL: response.requestURL,
            finalURL: response.finalURL,
            previousContent: previous,
            currentContent: snapshot
        )
    }

    // MARK: - Notifications

    private func notifyAuthenticationFailure() async -> Bool {
        let preferences = NotificationPreferences.shared
        let shouldNotify = preferences.shouldNotifyAuthenticationFailure()
        guard shouldNotify else { return false }
        guard await notificationsAvailable() else { return false }
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
        do {
            try await UNUserNotificationCenter.current().add(request)
            preferences.markAuthenticationFailureNotified()
            return true
        } catch {
            return false
        }
    }

    private func authenticationDetail(notified: Bool, reason: String) -> PortalPollHistoryDetail {
        PortalPollHistoryDetail(
            category: "登录状态",
            summary: "登录已过期",
            notificationTriggered: notified,
            technicalDetails: "\(reason)。登录失效通知\(notified ? "已发送" : "未发送或此前已发送")。",
            notificationEnabled: true
        )
    }

    private func postChangeNotification(category: String, summary: String) async -> Bool {
        guard await notificationsAvailable() else { return false }
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
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }

    private func notificationsAvailable() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    // MARK: - Networking

    private struct Response {
        let body: String
        let requestURL: String
        let finalURL: String
        let statusCode: Int
        let errorDescription: String?

        var isSuccessful: Bool { (200...299).contains(statusCode) }

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
                technicalDetails: technicalDetails ?? errorDescription,
                responseCode: statusCode,
                requestURL: requestURL,
                finalURL: finalURL
            )
        }
    }

    private func get(_ urlString: String, referer: String? = nil, ajax: Bool = false) async -> Response {
        guard let url = URL(string: urlString) else {
            return Response(
                body: "",
                requestURL: urlString,
                finalURL: urlString,
                statusCode: -1,
                errorDescription: "URL 无效：\(urlString)"
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            ajax
                ? "application/json,text/javascript,*/*;q=0.8"
                : "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        if let referer, !referer.isEmpty { request.setValue(referer, forHTTPHeaderField: "Referer") }
        if ajax { request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With") }
        do {
            let (data, response) = try await PortalHTTP.session.data(for: request)
            let http = response as? HTTPURLResponse
            let body = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: String.Encoding.utf8)
                ?? ""
            return Response(
                body: body,
                requestURL: urlString,
                finalURL: http?.url?.absoluteString ?? urlString,
                statusCode: http?.statusCode ?? -1,
                errorDescription: nil
            )
        } catch {
            return Response(
                body: "",
                requestURL: urlString,
                finalURL: urlString,
                statusCode: -1,
                errorDescription: "GET \(urlString) 失败：\(error.localizedDescription)"
            )
        }
    }

    /// Some EAMS controllers establish server-side state only after the user opens their entry
    /// page. Mirror the interactive flow before requesting a separate data URL.
    private func getNativePage(
        school: SchoolDefinition,
        nativeType: String,
        dataURL: String,
        initialReferer: String
    ) async -> Response {
        guard let item = school.quickItems.first(where: { $0.nativeType == nativeType }) else {
            return await get(dataURL, referer: initialReferer)
        }
        let entryURL = item.url(baseURL: school.baseUrl)
        let entry = await get(entryURL, referer: initialReferer)
        if !entry.isSuccessful || entry.isAuthenticationFailure { return entry }
        if canonicalURL(entry.finalURL) == canonicalURL(dataURL) { return entry }
        return await get(dataURL, referer: entry.finalURL)
    }

    private func canonicalURL(_ value: String) -> String {
        let withoutFragment = value.split(separator: "#", maxSplits: 1).first.map(String.init) ?? value
        return withoutFragment.hasSuffix("/") ? String(withoutFragment.dropLast()) : withoutFragment
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
