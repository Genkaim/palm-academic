import BackgroundTasks
import Foundation
import UserNotifications

/// Port of `PortalPollHistory` from `PortalPollHistory.kt`.
struct PortalPollHistoryEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let status: String
    let notificationTriggered: Bool
    let details: [PortalPollHistoryDetail]

    init(id: UUID = UUID(), timestamp: Date, status: String, notificationTriggered: Bool, details: [PortalPollHistoryDetail]) {
        self.id = id
        self.timestamp = timestamp
        self.status = status
        self.notificationTriggered = notificationTriggered
        self.details = details
    }
}

struct PortalPollHistoryDetail: Codable, Identifiable {
    let id: UUID
    let category: String
    let summary: String
    var changed: Bool
    var notificationTriggered: Bool
    var difference: String
    var technicalDetails: String?
    var notificationEnabled: Bool?
    var responseCode: Int?
    /// Mirrors Android's diagnostic fields. Optional keeps logs from earlier app versions
    /// decodable while allowing every new run to show the requested/final URL and both snapshots.
    var requestURL: String?
    var finalURL: String?
    var previousContent: String?
    var currentContent: String?

    init(
        id: UUID = UUID(),
        category: String,
        summary: String,
        changed: Bool = false,
        notificationTriggered: Bool = false,
        difference: String = "",
        technicalDetails: String? = nil,
        notificationEnabled: Bool? = nil,
        responseCode: Int? = nil,
        requestURL: String? = nil,
        finalURL: String? = nil,
        previousContent: String? = nil,
        currentContent: String? = nil
    ) {
        self.id = id
        self.category = category
        self.summary = summary
        self.changed = changed
        self.notificationTriggered = notificationTriggered
        self.difference = difference
        self.technicalDetails = technicalDetails
        self.notificationEnabled = notificationEnabled
        self.responseCode = responseCode
        self.requestURL = requestURL
        self.finalURL = finalURL
        self.previousContent = previousContent
        self.currentContent = currentContent
    }
}

enum PortalPollHistory {
    private static let entriesKey = "poll_history_entries"
    private static let acknowledgedPrefix = "poll_history_read_"
    private static let fileName = "portal_poll_history.json"
    private static let lock = NSLock()
    static let didChangeNotification = Notification.Name("portalPollHistoryDidChange")

    struct UnreadChange: Equatable {
        let entryID: UUID
        let nativeType: String
        let category: String
    }

    static func load() -> [PortalPollHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return readUnlocked()
    }

    static func append(_ entry: PortalPollHistoryEntry) {
        lock.lock()
        var entries = readUnlocked()
        entries.insert(entry, at: 0)
        writeUnlocked(entries)
        lock.unlock()
        publishChange()
    }

    static func clear() {
        lock.lock()
        try? FileManager.default.removeItem(at: historyFile)
        UserDefaults.standard.removeObject(forKey: entriesKey)
        lock.unlock()
        for type in ["schedule", "grade", "exam", "program"] {
            UserDefaults.standard.removeObject(forKey: acknowledgedPrefix + type)
        }
        publishChange()
    }

    static func replace(_ entries: [PortalPollHistoryEntry]) {
        lock.lock()
        writeUnlocked(entries)
        lock.unlock()
        publishChange()
    }

    /// Android stores this potentially large diagnostic record as an atomic JSON file. Keeping
    /// full before/after snapshots in UserDefaults can exceed the preferences daemon's practical
    /// limit and silently lose the very log needed to diagnose a failed comparison, so iOS uses
    /// the same file-backed model and migrates the earlier preference value once.
    private static var historyFile: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent(fileName)
    }

    private static func readUnlocked() -> [PortalPollHistoryEntry] {
        if let data = try? Data(contentsOf: historyFile),
           let entries = try? JSONDecoder().decode([PortalPollHistoryEntry].self, from: data) {
            return entries
        }
        guard let legacy = UserDefaults.standard.data(forKey: entriesKey),
              let entries = try? JSONDecoder().decode([PortalPollHistoryEntry].self, from: legacy) else {
            return []
        }
        writeUnlocked(entries)
        return entries
    }

    private static func writeUnlocked(_ entries: [PortalPollHistoryEntry]) {
        do {
            try FileManager.default.createDirectory(
                at: historyFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: historyFile, options: .atomic)
            UserDefaults.standard.removeObject(forKey: entriesKey)
        } catch {
            NSLog("portal history write failed: \(error.localizedDescription)")
        }
    }

    /// The same text representation Android writes through its CreateDocument contract. Keeping
    /// the file in the temporary directory makes it a normal iOS share-sheet item and avoids
    /// asking for broad Files access.
    static func exportURL(for entries: [PortalPollHistoryEntry]) -> URL? {
        guard !entries.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("掌上教务检查日志-\(formatter.string(from: Date())).txt")
        do {
            try exportText(entries).write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }

    static func latestUnreadChange() -> UnreadChange? {
        for entry in load() {
            if let detail = entry.details.first(where: { detail in
                guard detail.changed else { return false }
                let type = nativeType(for: detail.category)
                guard !type.isEmpty else { return false }
                let readAt = UserDefaults.standard.object(forKey: acknowledgedPrefix + type) as? Date ?? .distantPast
                return entry.timestamp > readAt
            }) {
                return UnreadChange(
                    entryID: entry.id,
                    nativeType: nativeType(for: detail.category),
                    category: detail.category
                )
            }
        }
        return nil
    }

    static func acknowledge(changeID: UUID) {
        guard let entry = load().first(where: { $0.id == changeID }),
              let detail = entry.details.first(where: { $0.changed }) else { return }
        let type = nativeType(for: detail.category)
        guard !type.isEmpty else { return }
        UserDefaults.standard.set(entry.timestamp, forKey: acknowledgedPrefix + type)
        publishChange()
    }

    private static func nativeType(for category: String) -> String {
        switch category {
        case "课表": return "schedule"
        case "成绩": return "grade"
        case "考试": return "exam"
        case "培养方案": return "program"
        default: return ""
        }
    }

    private static func publishChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    private static func exportText(_ entries: [PortalPollHistoryEntry]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var output = ["掌上教务后台检查日志"]
        for entry in entries {
            output += ["", "检查时间：\(formatter.string(from: entry.timestamp))", "检查状态：\(entry.status)"]
            for detail in entry.details {
                output += [
                    "", "项目：\(detail.category)", "结果：\(detail.summary)",
                    "检测到变化：\(detail.changed ? "是" : "否")",
                    "通知触发：\(detail.notificationTriggered ? "已成功发出" : "未发出")"
                ]
                if let enabled = detail.notificationEnabled {
                    output.append("该项提醒：\(enabled ? "已开启" : "未开启")")
                }
                if let code = detail.responseCode, !(200...299).contains(code) {
                    output.append("HTTP 状态：\(code)")
                }
                if let requestURL = detail.requestURL, !requestURL.isEmpty {
                    output.append("请求地址：\(requestURL)")
                }
                if let finalURL = detail.finalURL, !finalURL.isEmpty, finalURL != detail.requestURL {
                    output.append("最终地址：\(finalURL)")
                }
                if !detail.difference.isEmpty {
                    output += ["数据明细：", detail.difference]
                }
                if let previous = detail.previousContent, !previous.isEmpty {
                    output += ["比较前快照：", previous]
                }
                if let current = detail.currentContent, !current.isEmpty {
                    output += ["比较后快照：", current]
                }
                if let technical = detail.technicalDetails, !technical.isEmpty {
                    output += ["技术详情：", technical]
                }
            }
            output.append("---")
        }
        return output.joined(separator: "\n")
    }
}

/// Port of `PortalNotificationPreferences` from `PortalNotificationPreferences.kt`.
@MainActor
final class NotificationPreferences: ObservableObject {
    static let shared = NotificationPreferences()

    private enum Key {
        static let monitorEnabled = "monitor_enabled"
        static let schedule = "notify_schedule"
        static let grade = "notify_grade"
        static let exam = "notify_exam"
        static let authFailureNotified = "auth_failure_notified"
        static let interval = "interval"
        /// Builds before 0.4.6 defaulted the master worker switch to false, unlike Android, so a
        /// user could enable all three categories and still never enqueue a background job.
        static let automaticMonitorMigration = "automatic_monitor_migration_v2"
    }

    private let defaults = UserDefaults.standard

    @Published var monitorEnabled: Bool { didSet { defaults.set(monitorEnabled, forKey: Key.monitorEnabled); reschedule() } }
    @Published var scheduleEnabled: Bool { didSet { defaults.set(scheduleEnabled, forKey: Key.schedule); reschedule() } }
    @Published var gradeEnabled: Bool { didSet { defaults.set(gradeEnabled, forKey: Key.grade); reschedule() } }
    @Published var examEnabled: Bool { didSet { defaults.set(examEnabled, forKey: Key.exam); reschedule() } }
    @Published var intervalMinutes: Int { didSet { defaults.set(intervalMinutes, forKey: Key.interval); reschedule() } }

    private init() {
        if defaults.bool(forKey: Key.automaticMonitorMigration) {
            monitorEnabled = defaults.object(forKey: Key.monitorEnabled) as? Bool ?? true
        } else {
            // One-time repair of the old broken default. Once migrated, an explicit user toggle is
            // respected on every later launch.
            monitorEnabled = true
            defaults.set(true, forKey: Key.monitorEnabled)
            defaults.set(true, forKey: Key.automaticMonitorMigration)
        }
        scheduleEnabled = defaults.object(forKey: Key.schedule) as? Bool ?? true
        gradeEnabled = defaults.object(forKey: Key.grade) as? Bool ?? true
        examEnabled = defaults.object(forKey: Key.exam) as? Bool ?? true
        let stored = defaults.integer(forKey: Key.interval)
        intervalMinutes = stored > 0 ? stored : 30
    }

    var anyEnabled: Bool {
        scheduleEnabled || gradeEnabled || examEnabled
    }

    func isEnabled(_ key: String) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    func clearAuthenticationFailureMarker() {
        defaults.set(false, forKey: Key.authFailureNotified)
    }

    func shouldNotifyAuthenticationFailure() -> Bool {
        !defaults.bool(forKey: Key.authFailureNotified)
    }

    func markAuthenticationFailureNotified() {
        defaults.set(true, forKey: Key.authFailureNotified)
    }

    // MARK: - Snapshots

    /// Port of the snapshot persistence used by `PortalNotificationPreferences`.
    private static let snapshotPrefix = "snapshot_"

    func snapshot(for nativeType: String) -> String? {
        defaults.string(forKey: Self.snapshotPrefix + nativeType)
    }

    func storeSnapshot(_ value: String, for nativeType: String) {
        defaults.set(value, forKey: Self.snapshotPrefix + nativeType)
    }

    func clearSnapshots() {
        for type in ["schedule", "grade", "exam", "program"] {
            defaults.removeObject(forKey: Self.snapshotPrefix + type)
        }
        [
            "course_hash", "course_semester_id", "course_semantic_hash_v3",
            "course_semantic_semester_id_v3", "course_business_snapshot_v1",
            "course_business_semester_id_v1", "course_has_entries", "course_parsed_json_v2",
            "course_raw_v1", "grade_hash", "grade_business_snapshot_v1", "grade_parsed_json_v2",
            "grade_raw_v1", "exam_rows", "exam_rows_v2", "exam_business_snapshot_v1",
            "exam_parsed_json_v2", "exam_raw_v1"
        ].forEach { defaults.removeObject(forKey: $0) }
        defaults.set(false, forKey: Key.authFailureNotified)
    }

    // MARK: - Scheduling

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func reschedule() {
        PortalMonitor.shared.cancel()
        guard monitorEnabled, anyEnabled else { return }
        PortalMonitor.shared.schedule(intervalMinutes: intervalMinutes)
    }
}

/// Port of the `PortalMonitor` scheduling surface in `PortalPollWorker.kt`.
@MainActor
final class PortalMonitor {
    static let shared = PortalMonitor()
    static let channelID = "academic_changes"
    static let refreshTaskIdentifier = "cn.edu.cupk.portalreader.poll.refresh"
    static let notificationCategory = "PORTAL_CHANGE"

    private init() {}

    func configureChannel() {
        let center = UNUserNotificationCenter.current()
        let openAction = UNNotificationAction(
            identifier: "OPEN",
            title: "打开",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.notificationCategory,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    func schedule(intervalMinutes: Int) {
        cancel()
        let request = BGTaskRequestFactory.makeRefreshRequest(intervalMinutes: intervalMinutes)
        do {
            try BGTasks.shared.submit(request)
        } catch {
            NSLog("portal monitor schedule failed: \(error.localizedDescription)")
        }
    }

    func cancel() {
        BGTasks.shared.cancel(identifier: Self.refreshTaskIdentifier)
    }
}

/// Thin wrapper over `BGTaskScheduler` so the polling code stays testable and the single
/// identifier is declared in exactly one place.
final class BGTasks {
    static let shared = BGTasks()

    private let scheduler: BGTasksProtocol

    init(scheduler: BGTasksProtocol = BGTaskScheduler.shared) {
        self.scheduler = scheduler
    }

    func submit(_ request: BGAppRefreshTaskRequest) throws {
        try scheduler.submit(request)
    }

    func cancel(identifier: String) {
        scheduler.cancel(taskRequestWithIdentifier: identifier)
    }
}

/// Mirrors the Objective-C `-submitTaskRequest:error:` and
/// `-cancelTaskRequestWithIdentifier:` entry points on `BGTaskScheduler`.
protocol BGTasksProtocol {
    func submit(_ request: BGTaskRequest) throws
    func cancel(taskRequestWithIdentifier identifier: String)
}

extension BGTaskScheduler: BGTasksProtocol {}

enum BGTaskRequestFactory {
    /// iOS caps the refresh cadence, so the requested interval is clamped into the allowed window.
    static func makeRefreshRequest(intervalMinutes: Int) -> BGAppRefreshTaskRequest {
        let request = BGAppRefreshTaskRequest(identifier: PortalMonitor.refreshTaskIdentifier)
        let clamped = max(15, min(intervalMinutes, 180))
        request.earliestBeginDate = Date(timeIntervalSinceNow: Double(clamped) * 60)
        return request
    }
}

/// Timing metadata for deciding whether an iOS execution opportunity should invoke the shared
/// comparison worker. Detailed results continue to live in `PortalPollHistory`, just as on Android.
enum PortalPollTiming {
    private static let automaticAttemptKey = "poll_last_automatic_attempt"
    private static let completedCheckKey = "last_checked"

    static var lastAutomaticAttempt: Date? {
        UserDefaults.standard.object(forKey: automaticAttemptKey) as? Date
    }

    static var lastCompletedCheck: Date? {
        UserDefaults.standard.object(forKey: completedCheckKey) as? Date
    }

    static func recordAutomaticAttempt(at date: Date) {
        UserDefaults.standard.set(date, forKey: automaticAttemptKey)
    }

    static func recordCompletedCheck(at date: Date) {
        UserDefaults.standard.set(date, forKey: completedCheckKey)
    }

    static func resetForFreshSession() {
        UserDefaults.standard.removeObject(forKey: automaticAttemptKey)
        UserDefaults.standard.removeObject(forKey: completedCheckKey)
    }

    static func automaticCheckIsDue(intervalMinutes: Int, now: Date = Date()) -> Bool {
        if let attempt = lastAutomaticAttempt,
           lastCompletedCheck == nil || lastCompletedCheck! < attempt {
            // The last automatic pass started but did not complete successfully. Mirror
            // WorkManager's retry behaviour without spinning every time the app becomes active.
            return now.timeIntervalSince(attempt) >= 5 * 60
        }
        let latest = [lastAutomaticAttempt, lastCompletedCheck].compactMap { $0 }.max() ?? .distantPast
        return now.timeIntervalSince(latest) >= Double(max(15, intervalMinutes)) * 60
    }
}
