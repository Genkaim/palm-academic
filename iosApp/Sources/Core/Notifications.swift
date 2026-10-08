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

    init(
        id: UUID = UUID(),
        category: String,
        summary: String,
        changed: Bool = false,
        notificationTriggered: Bool = false,
        difference: String = "",
        technicalDetails: String? = nil,
        notificationEnabled: Bool? = nil,
        responseCode: Int? = nil
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
    }
}

enum PortalPollHistory {
    private static let entriesKey = "poll_history_entries"
    private static let limit = 60
    private static let lastAcknowledgedChangeKey = "poll_history_last_acknowledged_change"
    static let didChangeNotification = Notification.Name("portalPollHistoryDidChange")

    struct UnreadChange: Equatable {
        let entryID: UUID
        let nativeType: String
        let category: String
    }

    static func load() -> [PortalPollHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: entriesKey) else { return [] }
        return (try? JSONDecoder().decode([PortalPollHistoryEntry].self, from: data)) ?? []
    }

    static func append(_ entry: PortalPollHistoryEntry) {
        var entries = load()
        entries.insert(entry, at: 0)
        if entries.count > limit { entries = Array(entries.prefix(limit)) }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: entriesKey)
        }
        publishChange()
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: entriesKey)
        UserDefaults.standard.removeObject(forKey: lastAcknowledgedChangeKey)
        publishChange()
    }

    static func replace(_ entries: [PortalPollHistoryEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: entriesKey)
        }
        publishChange()
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
        let acknowledgedAt = UserDefaults.standard.object(forKey: lastAcknowledgedChangeKey) as? Date ?? .distantPast
        for entry in load() where entry.timestamp > acknowledgedAt {
            if let detail = entry.details.first(where: { $0.changed }) {
                return UnreadChange(
                    entryID: entry.id,
                    nativeType: nativeType(for: detail.category),
                    category: detail.category
                )
            }
        }
        return nil
    }

    static func acknowledge(changeID _: UUID) {
        // Mark every earlier entry as read too. A single UUID would make the next oldest changed
        // record reappear immediately after the newest notice is opened.
        UserDefaults.standard.set(Date(), forKey: lastAcknowledgedChangeKey)
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
                if !detail.difference.isEmpty {
                    output += ["数据明细：", detail.difference]
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
        static let program = "notify_program"
        static let authFailureNotified = "auth_failure_notified"
        static let interval = "interval"
    }

    private let defaults = UserDefaults.standard

    @Published var monitorEnabled: Bool { didSet { defaults.set(monitorEnabled, forKey: Key.monitorEnabled); reschedule() } }
    @Published var scheduleEnabled: Bool { didSet { defaults.set(scheduleEnabled, forKey: Key.schedule) } }
    @Published var gradeEnabled: Bool { didSet { defaults.set(gradeEnabled, forKey: Key.grade) } }
    @Published var examEnabled: Bool { didSet { defaults.set(examEnabled, forKey: Key.exam) } }
    @Published var programEnabled: Bool { didSet { defaults.set(programEnabled, forKey: Key.program) } }
    @Published var intervalMinutes: Int { didSet { defaults.set(intervalMinutes, forKey: Key.interval); reschedule() } }

    private init() {
        monitorEnabled = defaults.object(forKey: Key.monitorEnabled) as? Bool ?? false
        scheduleEnabled = defaults.object(forKey: Key.schedule) as? Bool ?? true
        gradeEnabled = defaults.object(forKey: Key.grade) as? Bool ?? true
        examEnabled = defaults.object(forKey: Key.exam) as? Bool ?? true
        programEnabled = defaults.object(forKey: Key.program) as? Bool ?? true
        let stored = defaults.integer(forKey: Key.interval)
        intervalMinutes = stored > 0 ? stored : 30
    }

    var anyEnabled: Bool {
        scheduleEnabled || gradeEnabled || examEnabled || programEnabled
    }

    func isEnabled(_ key: String) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    func clearAuthenticationFailureMarker() {
        defaults.set(false, forKey: Key.authFailureNotified)
    }

    func shouldNotifyAuthenticationFailure() -> Bool {
        let notified = defaults.bool(forKey: Key.authFailureNotified)
        defaults.set(true, forKey: Key.authFailureNotified)
        return !notified
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
    }

    // MARK: - Scheduling

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func reschedule() {
        PortalMonitor.shared.cancel()
        guard monitorEnabled else { return }
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
