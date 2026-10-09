import CryptoKit
import Foundation

/// Port of the `MaterialPage` model and `parseMaterialPage` from `WebMaterialReader.kt`.
///
/// The DOM selectors themselves stay in `cupk-reader.js`; this file only decodes the JSON that
/// the JS adapter publishes through the `PalmAcademicBridge` WebKit message handler. Sharing the
/// adapter keeps Android and iOS rendering identical for every university adapter.
struct MaterialPage: Identifiable {
    let id = UUID()
    let title: String
    let sourceUrl: String
    let choices: [MaterialChoice]
    let actions: [MaterialPageAction]
    let sections: [MaterialSection]

    var hasData: Bool { !sections.isEmpty }
}

struct MaterialChoiceOption: Hashable {
    let value: String
    let label: String
}

struct MaterialChoice: Identifiable, Hashable {
    let id: String
    let label: String
    let value: String
    let options: [MaterialChoiceOption]
}

struct MaterialPageAction: Hashable {
    let id: String
    let label: String
    let value: String
}

struct MaterialReaderAction {
    let id: String
    let value: String
    let token: Int
}

struct MaterialCourseSchedule: Hashable {
    let weeks: String
    let startSection: String
    let endSection: String
    let teacher: String
    let location: String
    let startTime: String
    let endTime: String
}

struct MaterialCardItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let subtitle: String
    let accent: String
    let fields: [(label: String, value: String)]
    let schedule: MaterialCourseSchedule?

    static func == (lhs: MaterialCardItem, rhs: MaterialCardItem) -> Bool {
        lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
            && lhs.fields.map(\.label) == rhs.fields.map(\.label)
            && lhs.fields.map(\.value) == rhs.fields.map(\.value)
            && lhs.schedule?.weeks == rhs.schedule?.weeks
            && lhs.schedule?.location == rhs.schedule?.location
            && lhs.schedule?.teacher == rhs.schedule?.teacher
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(subtitle)
        for field in fields {
            hasher.combine(field.label)
            hasher.combine(field.value)
        }
    }
}

struct MaterialStatItem: Hashable {
    let label: String
    let value: String
}

struct ScheduleDay: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let lessons: [MaterialCardItem]
}

struct ProgramModule: Identifiable {
    let id: String
    let title: String
    let depth: Int
    let status: String
    let requirements: [String]
    let headers: [String]
    let courses: [[String]]
    let children: [ProgramModule]

    func hasData() -> Bool {
        !title.isEmpty || !requirements.isEmpty || !courses.isEmpty || children.contains { $0.hasData() }
    }
}

/// Port of the `MaterialSection` sealed interface from `WebMaterialReader.kt`.
enum MaterialSection: Identifiable {
    case table(title: String, headers: [String], rows: [[String]])
    case fields(title: String, fields: [(label: String, value: String)])
    case text(title: String, paragraphs: [String])
    case links(title: String, links: [(title: String, url: String)])
    case schedule(title: String, semesterStartDate: String, days: [ScheduleDay])
    case cards(title: String, cards: [MaterialCardItem])
    case program(title: String, completedCredits: String, requiredCredits: String, modules: [ProgramModule])
    case stats(title: String, items: [MaterialStatItem])

    var id: String {
        switch self {
        case .table(let title, _, let rows): return "table-\(title)-\(rows.count)"
        case .fields(let title, let fields): return "fields-\(title)-\(fields.count)"
        case .text(let title, let paragraphs): return "text-\(title)-\(paragraphs.count)"
        case .links(let title, let links): return "links-\(title)-\(links.count)"
        case .schedule(let title, _, let days): return "schedule-\(title)-\(days.count)"
        case .cards(let title, let cards): return "cards-\(title)-\(cards.count)"
        case .program(let title, _, _, let modules): return "program-\(title)-\(modules.count)"
        case .stats(let title, let items): return "stats-\(title)-\(items.count)"
        }
    }

    var title: String {
        switch self {
        case .table(let title, _, _),
             .fields(let title, _),
             .text(let title, _),
             .links(let title, _),
             .schedule(let title, _, _),
             .cards(let title, _),
             .program(let title, _, _, _),
             .stats(let title, _):
            return title
        }
    }
}

enum MaterialPageParser {
    /// Port of `parseMaterialPage`.
    static func parse(_ json: String) -> MaterialPage? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var sections: [MaterialSection] = []
        for section in (root["sections"] as? [[String: Any]] ?? []) {
            let title = section["title"] as? String ?? ""
            switch section["type"] as? String {
            case "schedule":
                guard let daysJSON = section["days"] as? [[String: Any]] else { continue }
                let days = daysJSON.map { day in
                    ScheduleDay(
                        name: day["name"] as? String ?? "",
                        lessons: parseCards(day["lessons"] as? [[String: Any]])
                    )
                }
                sections.append(.schedule(
                    title: title,
                    semesterStartDate: section["semesterStartDate"] as? String ?? "",
                    days: days
                ))
            case "cards":
                sections.append(.cards(title: title, cards: parseCards(section["cards"] as? [[String: Any]])))
            case "stats":
                guard let itemsJSON = section["items"] as? [[String: Any]] else { continue }
                let items = itemsJSON.map {
                    MaterialStatItem(label: $0["label"] as? String ?? "", value: $0["value"] as? String ?? "")
                }
                sections.append(.stats(title: title, items: items))
            case "program":
                sections.append(.program(
                    title: title,
                    completedCredits: section["completedCredits"] as? String ?? "",
                    requiredCredits: section["requiredCredits"] as? String ?? "",
                    modules: parseProgramModules(section["modules"] as? [[String: Any]])
                ))
            case "table":
                guard let headers = section["headers"] as? [String],
                      let rows = section["rows"] as? [[String]] else { continue }
                sections.append(.table(title: title, headers: headers, rows: rows))
            case "fields":
                guard let fieldsJSON = section["fields"] as? [[String: Any]] else { continue }
                let fields = fieldsJSON.map {
                    (label: $0["label"] as? String ?? "", value: $0["value"] as? String ?? "")
                }
                sections.append(.fields(title: title, fields: fields))
            case "text":
                guard let paragraphs = section["paragraphs"] as? [String] else { continue }
                sections.append(.text(title: title, paragraphs: paragraphs))
            case "links":
                guard let linksJSON = section["links"] as? [[String: Any]] else { continue }
                let links = linksJSON.map {
                    (title: $0["title"] as? String ?? "", url: $0["url"] as? String ?? "")
                }
                sections.append(.links(title: title, links: links))
            default:
                continue
            }
        }

        return MaterialPage(
            title: root["title"] as? String ?? "",
            sourceUrl: root["sourceUrl"] as? String ?? "",
            choices: parseChoices(root["choices"] as? [[String: Any]]),
            actions: parseActions(root["actions"] as? [[String: Any]]),
            sections: sections
        )
    }

    private static func parseChoices(_ array: [[String: Any]]?) -> [MaterialChoice] {
        (array ?? []).map { choice in
            let optionsJSON = choice["options"] as? [[String: Any]] ?? []
            return MaterialChoice(
                id: choice["id"] as? String ?? "",
                label: choice["label"] as? String ?? "",
                value: choice["value"] as? String ?? "",
                options: optionsJSON.map {
                    MaterialChoiceOption(value: $0["value"] as? String ?? "", label: $0["label"] as? String ?? "")
                }
            )
        }
    }

    private static func parseActions(_ array: [[String: Any]]?) -> [MaterialPageAction] {
        (array ?? []).map {
            MaterialPageAction(
                id: $0["id"] as? String ?? "",
                label: $0["label"] as? String ?? "",
                value: $0["value"] as? String ?? ""
            )
        }
    }

    private static func parseProgramModules(_ array: [[String: Any]]?) -> [ProgramModule] {
        (array ?? []).map { module in
            ProgramModule(
                id: module["id"] as? String ?? "",
                title: module["title"] as? String ?? "",
                depth: module["depth"] as? Int ?? 1,
                status: module["status"] as? String ?? "",
                requirements: module["requirements"] as? [String] ?? [],
                headers: module["headers"] as? [String] ?? [],
                courses: (module["courses"] as? [[String]] ?? []),
                children: parseProgramModules(module["children"] as? [[String: Any]])
            )
        }
    }

    private static func parseCards(_ array: [[String: Any]]?) -> [MaterialCardItem] {
        (array ?? []).map { item in
            let fieldsJSON = item["fields"] as? [[String: Any]] ?? []
            let scheduleJSON = item["schedule"] as? [String: Any]
            return MaterialCardItem(
                title: item["title"] as? String ?? "",
                subtitle: item["subtitle"] as? String ?? "",
                accent: item["accent"] as? String ?? "",
                fields: fieldsJSON.map {
                    (label: $0["label"] as? String ?? "", value: $0["value"] as? String ?? "")
                },
                schedule: scheduleJSON.map { value in
                    MaterialCourseSchedule(
                        weeks: value["weeks"] as? String ?? "",
                        startSection: value["startSection"] as? String ?? "",
                        endSection: value["endSection"] as? String ?? "",
                        teacher: value["teacher"] as? String ?? "",
                        location: value["location"] as? String ?? "",
                        startTime: value["startTime"] as? String ?? "",
                        endTime: value["endTime"] as? String ?? ""
                    )
                }
            )
        }
    }
}

/// Port of `MaterialPageCache`: the native UI renders the last snapshot immediately while a fresh
/// fetch runs behind it.
enum MaterialPageCache {
    private static let directory = "material_page_cache"

    static func load(url: String) -> MaterialPage? {
        guard let data = try? Data(contentsOf: cacheFile(url: url)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return MaterialPageParser.parse(text)
    }

    static func loadRaw(url: String) -> String? {
        guard let data = try? Data(contentsOf: cacheFile(url: url)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(url: String, json: String) {
        let target = cacheFile(url: url)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? json.write(to: target, atomically: true, encoding: .utf8)
    }

    /// A successful new login starts a new account/session data lifetime. Removing the directory
    /// atomically prevents any redrawn screen from flashing a previous login's snapshot before its
    /// own reader finishes, while the baseline prefetch repopulates every declared quick entry.
    static func clearAll() {
        try? FileManager.default.removeItem(at: cacheDirectoryURL())
    }

    private static func cacheFile(url: String) -> URL {
        let digest = SHA256Helper.hexDigest(url)
        return cacheDirectoryURL().appendingPathComponent("\(digest).json")
    }

    private static func cacheDirectoryURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(directory)
    }
}

enum SHA256Helper {
    static func hexDigest(_ value: String) -> String {
        // SHA256.hash(data:into:) only exists on Apple platforms, so the digest is
        // taken from the returned collection instead.
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
