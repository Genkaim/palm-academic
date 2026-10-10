import Foundation

/// Mirrors the Kotlin `PortalItem` in `PortalCatalog.kt`.
struct PortalItem: Codable, Identifiable, Hashable {
    let title: String
    let path: String
    let quick: Bool?
    let nativeType: String?

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case title, path, quick, nativeType
    }

    init(title: String, path: String, quick: Bool? = nil, nativeType: String? = nil) {
        self.title = title
        self.path = path
        self.quick = quick
        self.nativeType = nativeType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        path = try container.decode(String.self, forKey: .path)
        quick = try container.decodeIfPresent(Bool.self, forKey: .quick)
        nativeType = try container.decodeIfPresent(String.self, forKey: .nativeType)
    }

    /// Mirrors `PortalItem.url`: absolute paths are used verbatim.
    func url(baseURL: String) -> String {
        if path.hasPrefix("http") { return path }
        return baseURL.hasSuffix("/") ? String(baseURL.dropLast()) + path : baseURL + path
    }
}

struct PortalGroup: Codable, Identifiable, Hashable {
    let title: String
    let items: [PortalItem]

    var id: String { title }
}

/// Mirrors `PortalMonitorDefinition` in `PortalCatalog.kt`.
struct PortalMonitorDefinition {
    let coursePagePath: String
    let courseDataPathTemplate: String
    let gradeDataPathTemplate: String
    let examDataPathTemplate: String
    let semesterIdPatterns: [String]
    let studentIdPatterns: [String]

    func url(baseURL: String, path: String) -> String {
        if path.hasPrefix("https://") { return path }
        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return trimmedBase + "/" + path.drop(while: { $0 == "/" })
    }

    func courseDataURL(baseURL: String, semesterId: String, studentId: String) -> String {
        dataURL(baseURL: baseURL, template: courseDataPathTemplate, semesterId: semesterId, studentId: studentId)
    }

    func gradeDataURL(baseURL: String, semesterId: String, studentId: String) -> String {
        dataURL(baseURL: baseURL, template: gradeDataPathTemplate, semesterId: semesterId, studentId: studentId)
    }

    func examDataURL(baseURL: String, semesterId: String, studentId: String) -> String {
        dataURL(baseURL: baseURL, template: examDataPathTemplate, semesterId: semesterId, studentId: studentId)
    }

    private func dataURL(baseURL: String, template: String, semesterId: String, studentId: String) -> String {
        let resolved = template
            .replacingOccurrences(of: "{semesterId}", with: semesterId)
            .replacingOccurrences(of: "{studentId}", with: studentId)
        return url(baseURL: baseURL, path: resolved)
    }
}

/// Mirrors `SchoolDefinition` in `PortalCatalog.kt`.
struct SchoolDefinition: Codable {
    let id: String
    let name: String
    let baseUrl: String
    let readerAdapter: String
    let groups: [PortalGroup]
    let monitor: MonitorPayload
    let auth: AuthPayload?

    struct AuthPayload: Codable {
        let type: String?
        let loginUrl: String?
        let homePath: String?
        let successUrlPrefixes: [String]?
        let sessionCookieHosts: [String]?
        let sessionCookieNames: [String]?
        let captcha: CaptchaPayload?
        let engine: AuthEnginePayload?

        var isWebOnly: Bool { type == "web" }
        var usesEngine: Bool { type == "engine" && engine != nil }
        var resolvedSuccessPrefixes: [String] { successUrlPrefixes ?? [] }
        var resolvedCookieHosts: [String] { sessionCookieHosts ?? [] }
        var resolvedCookieNames: [String] { sessionCookieNames ?? ["SESSION"] }

        struct CaptchaPayload: Codable {
            let required: Bool
            let imageUrl: String?
            let refreshQueryParameter: String?
        }
    }

    /// Mirrors the `auth.engine` object consumed by `AuthRepository.loginWithEngine` on Android:
    /// the school definition describes the whole login handshake (requests, value extraction,
    /// encryption) as data, and the app only executes it.
    struct AuthEnginePayload: Codable {
        let steps: [Step]
        let outcome: Outcome?

        struct Step: Codable {
            let id: String?
            let request: Request?
            let extract: Extract?
            let transform: Transform?

            struct Request: Codable {
                let method: String?
                let url: String
                let headers: [String: String]?
                let contentType: String?
                let form: [String: String]?
                let json: [String: String]?
                let body: String?
            }

            struct Extract: Codable {
                let from: String?
                let regex: String
                let group: Int?
            }

            struct Transform: Codable {
                let algorithm: String
                let publicKey: String?
                let input: String?
            }
        }

        struct Outcome: Codable {
            let captcha: Rule?
            let rejected: Rule?
            let success: Success?

            struct Rule: Codable {
                let statusCodes: [Int]?
                let bodyContains: [String]?
                let message: String?
            }

            struct Success: Codable {
                let finalUrlPrefixes: [String]?
                let cookies: [String]?
                let statusCodes: [Int]?
            }
        }
    }

    struct MonitorPayload: Codable {
        let coursePagePath: String?
        let courseDataPathTemplate: String?
        let gradeDataPathTemplate: String?
        let examDataPathTemplate: String?

        enum CodingKeys: String, CodingKey {
            case coursePagePath, courseDataPathTemplate, gradeDataPathTemplate, examDataPathTemplate
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            coursePagePath = try container.decodeIfPresent(String.self, forKey: .coursePagePath)
            courseDataPathTemplate = try container.decodeIfPresent(String.self, forKey: .courseDataPathTemplate)
            gradeDataPathTemplate = try container.decodeIfPresent(String.self, forKey: .gradeDataPathTemplate)
            examDataPathTemplate = try container.decodeIfPresent(String.self, forKey: .examDataPathTemplate)
        }

        var resolved: PortalMonitorDefinition {
            PortalMonitorDefinition(
                coursePagePath: coursePagePath ?? "/for-std/course-table",
                courseDataPathTemplate: courseDataPathTemplate
                    ?? "/for-std/course-table/get-data?bizTypeId=2&semesterId={semesterId}&dataId={studentId}&searchTeachingSyllabus=true",
                gradeDataPathTemplate: gradeDataPathTemplate ?? "/for-std/grade/sheet",
                examDataPathTemplate: examDataPathTemplate ?? "/for-std/exam-arrange",
                semesterIdPatterns: [
                    "currentSemester\\s*=.*?[\"']?id[\"']?\\s*:\\s*(\\d+)",
                    "var\\s+semesterId\\s*=\\s*(\\d+)",
                    "[\"']semesterId[\"']\\s*:\\s*[\"']?(\\d+)"
                ],
                studentIdPatterns: [
                    "/for-std/course-table/info/(\\d+)",
                    "[\"']studentId[\"']\\s*:\\s*[\"']?(\\d+)",
                    "[\"']dataId[\"']\\s*:\\s*[\"']?(\\d+)"
                ]
            )
        }
    }

    var resolvedMonitor: PortalMonitorDefinition { monitor.resolved }

    /// Mirrors `SchoolDefinition.quickItems`.
    var quickItems: [PortalItem] {
        groups.flatMap(\.items).filter { $0.quick == true }
    }
}

/// Mirrors `SchoolProfile` / `SchoolIndex` in `PortalCatalog.kt`.
struct SchoolProfile: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let origin: String
    let definitionAsset: String
    let readerConfig: ReaderConfig
    /// Local imports live outside the cloud-managed cache and are the only removable profiles.
    let isImported: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, origin, definitionAsset, readerConfig
    }

    struct ReaderConfig: Codable, Hashable {
        let scheduleProfiles: [ScheduleProfile]

        init(scheduleProfiles: [ScheduleProfile]) {
            self.scheduleProfiles = scheduleProfiles
        }

        enum CodingKeys: String, CodingKey { case scheduleProfiles }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            scheduleProfiles = try container.decodeIfPresent([ScheduleProfile].self, forKey: .scheduleProfiles) ?? []
        }
    }

    struct ScheduleProfile: Codable, Hashable {
        let locationPattern: String?
        let unitTimes: [String: [String]]

        enum CodingKeys: String, CodingKey { case locationPattern, unitTimes }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            locationPattern = try container.decodeIfPresent(String.self, forKey: .locationPattern)
            unitTimes = try container.decodeIfPresent([String: [String]].self, forKey: .unitTimes) ?? [:]
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        origin = try container.decode(String.self, forKey: .origin)
        definitionAsset = try container.decode(String.self, forKey: .definitionAsset)
        readerConfig = try container.decodeIfPresent(ReaderConfig.self, forKey: .readerConfig) ?? ReaderConfig(scheduleProfiles: [])
        isImported = false
    }

    init(
        id: String,
        name: String,
        origin: String,
        definitionAsset: String,
        readerConfig: ReaderConfig,
        isImported: Bool = false
    ) {
        self.id = id
        self.name = name
        self.origin = origin
        self.definitionAsset = definitionAsset
        self.readerConfig = readerConfig
        self.isImported = isImported
    }

    init(fromJSONObject object: [String: Any], isImported: Bool = false) throws {
        guard let id = object["id"] as? String,
              let name = object["name"] as? String,
              let origin = object["origin"] as? String,
              let definitionAsset = object["definitionAsset"] as? String else {
            throw PortalError.invalidSchoolDefinition
        }
        let readerConfig: ReaderConfig
        if let raw = object["readerConfig"],
           let data = try? JSONSerialization.data(withJSONObject: raw) {
            readerConfig = (try? JSONDecoder().decode(ReaderConfig.self, from: data))
                ?? ReaderConfig(scheduleProfiles: [])
        } else {
            readerConfig = ReaderConfig(scheduleProfiles: [])
        }
        self.init(
            id: id,
            name: name,
            origin: origin.hasSuffix("/") ? String(origin.dropLast()) : origin,
            definitionAsset: definitionAsset,
            readerConfig: readerConfig,
            isImported: isImported
        )
    }

    /// Mirrors `SchoolAdapterRepository.parseDefaultUnitTimes`.
    var fallbackUnitTimes: [String: (start: String, end: String)] {
        guard let profile = readerConfig.scheduleProfiles.first(where: { ($0.locationPattern ?? "").isEmpty })
            ?? readerConfig.scheduleProfiles.first else { return [:] }
        var result: [String: (start: String, end: String)] = [:]
        for (section, range) in profile.unitTimes where range.count >= 2 {
            result[section] = (range[0], range[1])
        }
        return result
    }
}

struct SchoolIndex: Codable {
    let builtIn: [SchoolProfile]
    let configVersion: Int

    init(builtIn: [SchoolProfile], configVersion: Int) {
        self.builtIn = builtIn
        self.configVersion = configVersion
    }

    enum CodingKeys: String, CodingKey {
        case builtIn, schools, configVersion, schemaVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        guard version == 1 || version == 2 else { throw PortalError.unsupportedSchema }
        builtIn = try container.decodeIfPresent([SchoolProfile].self, forKey: .builtIn)
            ?? container.decodeIfPresent([SchoolProfile].self, forKey: .schools)
            ?? []
        configVersion = try container.decodeIfPresent(Int.self, forKey: .configVersion) ?? 1
    }

    /// Writes the current shape (schemaVersion 2, key `builtIn`). The decoder above
    /// also accepts the schemaVersion 1 `schools` key, which has no encoder side.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(builtIn, forKey: .builtIn)
        try container.encode(configVersion, forKey: .configVersion)
        try container.encode(2, forKey: .schemaVersion)
    }
}

struct SchoolRefreshResult {
    let schoolCount: Int
    let downloadedFileCount: Int
}

struct SchoolAuthorInfo: Identifiable {
    let schoolID: String
    let schoolName: String
    let authorName: String
    let contact: String
    let isImported: Bool

    var id: String { schoolID }
}

enum PortalError: LocalizedError {
    case invalidSchoolDefinition
    case unsupportedSchema
    case invalidResponse
    case requestFailed(Int)
    case emptySalt
    case loginRejected(String)
    case engineFailed(String)
    case noSession
    case webViewSessionMissing
    case sessionExpired
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidSchoolDefinition: return "学校配置无效"
        case .unsupportedSchema: return "不支持的学校配置版本"
        case .invalidResponse: return "教务系统返回内容无法解析"
        case .requestFailed(let code): return "请求失败（HTTP \(code)），请检查网络或校园网/VPN"
        case .emptySalt: return "无法获取登录校验信息"
        case .loginRejected(let message): return message
        case .engineFailed(let message): return message
        case .noSession: return "登录请求已完成，但没有收到会话信息，请重试"
        case .webViewSessionMissing: return "登录会话未能写入系统浏览器"
        case .sessionExpired: return "登录已过期，请重新登录"
        case .unavailable: return "教务系统暂时无法访问"
        }
    }
}
