import Foundation

/// Port of `SchoolAdapterRepository` from `PortalCatalog.kt`.
///
/// The Android version merges bundled assets with a GitHub-downloaded overlay. This port keeps
/// the same validation rules so a school definition can never ship an insecure base URL or an
/// asset path that escapes the cache root.
@MainActor
final class SchoolCatalog: ObservableObject {
    static let shared = SchoolCatalog()

    static let indexAsset = "schools/index.json"
    static let defaultSchoolID = "cupk"
    static let defaultOrigin = "https://eams.cupk.edu.cn"
    private static let remoteCacheDirectory = "remote-school-adapters"
    private static let selectedSchoolKey = "active_school"
    private static let emailPattern = try! NSRegularExpression(
        pattern: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$"
    )

    @Published private(set) var profiles: [SchoolProfile] = []
    @Published private(set) var selectedSchoolID: String = SchoolCatalog.defaultSchoolID
    @Published private(set) var definition: SchoolDefinition?
    @Published private(set) var loadError: String?

    private var cachedDefinition: SchoolDefinition?
    private var adapterScriptCache: [String: String] = [:]
    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Lifecycle

    func initialize() {
        profiles = (try? readProfiles()) ?? []
        if let saved = UserDefaults.standard.string(forKey: Self.selectedSchoolKey),
           profiles.contains(where: { $0.id == saved }) {
            selectedSchoolID = saved
        } else {
            selectedSchoolID = SchoolCatalog.defaultSchoolID
        }
        cachedDefinition = nil
        adapterScriptCache.removeAll()
        // Warm the definition off the critical path so the first home render does not parse JSON.
        Task.detached(priority: .utility) { [weak self] in
            try? await self?.loadDefinitionAsync()
        }
    }

    var options: [SchoolProfile] { profiles }

    var activeProfile: SchoolProfile? {
        profiles.first { $0.id == selectedSchoolID }
            ?? profiles.first { $0.id == SchoolCatalog.defaultSchoolID }
            ?? profiles.first
    }

    var hasSelectedSchool: Bool {
        UserDefaults.standard.string(forKey: Self.selectedSchoolKey) != nil
    }

    var origin: String { activeProfile?.origin ?? SchoolCatalog.defaultOrigin }
    var baseURL: String { definition?.baseUrl ?? "\(origin)/student" }

    /// Mirrors `SchoolAdapterRepository.select`: returns true when the active school changed.
    @discardableResult
    func select(schoolID: String) -> Bool {
        guard profiles.contains(where: { $0.id == schoolID }) else { return false }
        if selectedSchoolID == schoolID,
           UserDefaults.standard.string(forKey: Self.selectedSchoolKey) == schoolID {
            return false
        }
        selectedSchoolID = schoolID
        cachedDefinition = nil
        adapterScriptCache.removeAll()
        UserDefaults.standard.set(schoolID, forKey: Self.selectedSchoolKey)
        NotificationPreferences.shared.clearSnapshots()
        return true
    }

    // MARK: - Definition loading

    func loadDefinition() -> SchoolDefinition? {
        if let cachedDefinition, cachedDefinition.id == selectedSchoolID { return cachedDefinition }
        guard let profile = activeProfile else { return nil }
        guard let root = readJSONObject(assetPath: profile.definitionAsset) else {
            loadError = "学校配置加载失败"
            return nil
        }
        do {
            try validateDefinition(root)
            let data = try JSONSerialization.data(withJSONObject: root)
            let decoded = try JSONDecoder().decode(SchoolDefinition.self, from: data)
            cachedDefinition = decoded
            definition = decoded
            return decoded
        } catch {
            loadError = error.localizedDescription
            return nil
        }
    }

    private func loadDefinitionAsync() async -> SchoolDefinition? {
        await withCheckedContinuation { continuation in
            continuation.resume(returning: nil)
        }
    }

    /// Mirrors `SchoolAdapterRepository.readAdapterScript`.
    func readAdapterScript(assetPath: String) -> String {
        let key = "\(selectedSchoolID):\(assetPath)"
        if let cached = adapterScriptCache[key] { return cached }
        let text = readConfiguredText(assetPath: assetPath) ?? ""
        adapterScriptCache[key] = text
        return text
    }

    /// The raw `readerConfig` object is injected into the JS adapter as `schoolConfig`.
    func readerConfigJSON() -> String {
        guard let profile = activeProfile,
              let data = try? JSONEncoder().encode(profile.readerConfig),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    // MARK: - GitHub refresh

    /// Port of `SchoolAdapterRepository.refreshFromGitHub`.
    func refreshFromGitHub() async throws -> SchoolRefreshResult {
        let remoteRepositoryRoot = "app/src/main/assets"
        let indexText = try await GitHubRepository.repositoryFile("\(remoteRepositoryRoot)/\(Self.indexAsset)")
        let remoteIndex = try parseIndex(indexText)
        guard !remoteIndex.builtIn.isEmpty else { throw PortalError.invalidSchoolDefinition }

        var downloaded: [(path: String, content: String)] = []
        var seenAssets = Set<String>()
        for profile in remoteIndex.builtIn {
            let definitionPath = profile.definitionAsset
            if !seenAssets.contains(definitionPath) {
                seenAssets.insert(definitionPath)
                try requireSafeAssetPath(definitionPath, prefix: "schools/", suffix: ".json")
                let definitionText = try await GitHubRepository.repositoryFile("\(remoteRepositoryRoot)/\(definitionPath)")
                guard let definitionObject = try JSONSerialization.jsonObject(with: Data(definitionText.utf8)) as? [String: Any] else {
                    throw PortalError.invalidSchoolDefinition
                }
                try validateDefinition(definitionObject)
                downloaded.append((definitionPath, definitionText))

                guard let adapterPath = definitionObject["readerAdapter"] as? String else {
                    throw PortalError.invalidSchoolDefinition
                }
                try requireSafeAssetPath(adapterPath, prefix: "adapters/", suffix: ".js")
                let adapterText = try await GitHubRepository.repositoryFile("\(remoteRepositoryRoot)/\(adapterPath)")
                downloaded.append((adapterPath, adapterText))
            }
        }

        let cacheRoot = try remoteCacheRoot()
        for entry in downloaded {
            try writeRemoteFile(cacheRoot: cacheRoot, assetPath: entry.path, content: entry.content)
        }
        // Commit the validated index last so a partial download never becomes active.
        try writeRemoteFile(cacheRoot: cacheRoot, assetPath: Self.indexAsset, content: indexJSON(remoteIndex))

        profiles = (try? readProfiles()) ?? profiles
        cachedDefinition = nil
        adapterScriptCache.removeAll()
        if !profiles.contains(where: { $0.id == selectedSchoolID }) {
            selectedSchoolID = profiles.first { $0.id == SchoolCatalog.defaultSchoolID }?.id ?? profiles[0].id
            UserDefaults.standard.set(selectedSchoolID, forKey: Self.selectedSchoolKey)
        }
        definition = nil
        return SchoolRefreshResult(schoolCount: profiles.count, downloadedFileCount: downloaded.count + 1)
    }

    // MARK: - Index parsing

    private func readProfiles() throws -> [SchoolProfile] {
        let bundledText = try readBundledText(assetPath: Self.indexAsset)
        let bundled = try parseIndex(bundledText)

        let cachedText = remoteFile(assetPath: Self.indexAsset).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        if let cachedText,
           let cachedData = cachedText.data(using: .utf8),
           let cachedObject = try? JSONSerialization.jsonObject(with: cachedData) as? [String: Any],
           (cachedObject["schemaVersion"] as? Int) == 2,
           let cachedIndex = try? parseIndex(cachedText) {
            // A newer bundled configVersion always wins over the downloaded overlay.
            return bundled.configVersion > cachedIndex.configVersion ? bundled.builtIn : cachedIndex.builtIn
        }
        return bundled.builtIn
    }

    private func parseIndex(_ text: String) throws -> SchoolIndex {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schemaVersion"] as? Int else {
            throw PortalError.invalidSchoolDefinition
        }
        let rawProfiles: [[String: Any]]
        switch version {
        case 1:
            rawProfiles = object["schools"] as? [[String: Any]] ?? []
        case 2:
            rawProfiles = object["builtIn"] as? [[String: Any]] ?? []
        default:
            throw PortalError.unsupportedSchema
        }
        let profiles = try rawProfiles.map { try SchoolProfile(fromJSONObject: $0) }
        guard Set(profiles.map(\.id)).count == profiles.count else {
            throw PortalError.invalidSchoolDefinition
        }
        return SchoolIndex(
            builtIn: profiles,
            configVersion: object["configVersion"] as? Int ?? 1
        )
    }

    private func indexJSON(_ index: SchoolIndex) -> String {
        let profiles: [[String: Any]] = index.builtIn.map { profile in
            [
                "id": profile.id,
                "name": profile.name,
                "origin": profile.origin,
                "definitionAsset": profile.definitionAsset,
                "readerConfig": [
                    "scheduleProfiles": profile.readerConfig.scheduleProfiles.map { schedule in
                        [
                            "locationPattern": schedule.locationPattern as Any,
                            "unitTimes": schedule.unitTimes
                        ]
                    }
                ]
            ]
        }
        let object: [String: Any] = [
            "schemaVersion": 2,
            "configVersion": index.configVersion,
            "builtIn": profiles,
            "imported": [String]()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    // MARK: - Validation

    /// Port of `SchoolAdapterRepository.validateDefinition`.
    private func validateDefinition(_ root: [String: Any]) throws {
        guard (root["schemaVersion"] as? Int) == 1 else { throw PortalError.invalidSchoolDefinition }
        guard root["groups"] != nil else { throw PortalError.invalidSchoolDefinition }
        guard let baseUrl = root["baseUrl"] as? String, baseUrl.hasPrefix("https://") else {
            throw PortalError.invalidSchoolDefinition
        }
        guard let author = root["author"] as? [String: Any],
              let authorName = author["name"] as? String, !authorName.isEmpty else {
            throw PortalError.invalidSchoolDefinition
        }
        guard let email = author["email"] as? String,
              Self.emailPattern.firstMatch(in: email, range: NSRange(email.startIndex..., in: email)) != nil else {
            throw PortalError.invalidSchoolDefinition
        }
        guard let adapter = root["readerAdapter"] as? String else { throw PortalError.invalidSchoolDefinition }
        try requireSafeAssetPath(adapter, prefix: "adapters/", suffix: ".js")

        guard let monitor = root["monitor"] as? [String: Any] else { throw PortalError.invalidSchoolDefinition }
        for key in ["coursePagePath", "courseDataPathTemplate", "gradeDataPathTemplate", "examDataPathTemplate"] {
            guard let path = monitor[key] as? String, path.hasPrefix("/") || path.hasPrefix("https://") else {
                throw PortalError.invalidSchoolDefinition
            }
        }
        guard let template = monitor["courseDataPathTemplate"] as? String,
              template.contains("{semesterId}") else {
            throw PortalError.invalidSchoolDefinition
        }
        for key in ["semesterIdPatterns", "studentIdPatterns"] {
            if let patterns = monitor[key] as? [String] {
                guard !patterns.isEmpty else { throw PortalError.invalidSchoolDefinition }
                for pattern in patterns where (try? NSRegularExpression(pattern: pattern)) == nil {
                    throw PortalError.invalidSchoolDefinition
                }
            }
        }
        try validateFourQuickEntries(root)
    }

    /// Port of `SchoolAdapterRepository.validateFourQuickEntries`.
    private func validateFourQuickEntries(_ root: [String: Any]) throws {
        var quickTypes: [String] = []
        if let groups = root["groups"] as? [[String: Any]] {
            for group in groups {
                guard let items = group["items"] as? [[String: Any]] else { continue }
                for item in items where (item["quick"] as? Bool) == true {
                    quickTypes.append(item["nativeType"] as? String ?? "")
                }
            }
        }
        let required: Set<String> = ["schedule", "grade", "exam", "program"]
        guard quickTypes.count == required.count, Set(quickTypes) == required else {
            throw PortalError.invalidSchoolDefinition
        }
    }

    /// Port of `SchoolAdapterRepository.requireSafeAssetPath`.
    private func requireSafeAssetPath(_ path: String, prefix: String, suffix: String) throws {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/-")
        guard path.hasPrefix(prefix), path.hasSuffix(suffix),
              !path.contains(".."),
              path.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw PortalError.invalidSchoolDefinition
        }
    }

    // MARK: - Resource access

    /// Resolves a catalog-relative path such as `schools/index.json` or `adapters/cupk-reader.js`
    /// to a file inside the app bundle.
    ///
    /// The extension has to be read back off the path rather than assumed. Both directories are
    /// folder references, so the layout is preserved in the bundle, but the assets do not share one
    /// extension: hard-coding `json` made every adapter resolve as `cupk-reader.js.json`, which does
    /// not exist, so `readAdapterScript` silently returned an empty string and the reader reported
    /// "适配器脚本未安装" while the school catalog itself loaded fine.
    private func bundledURL(_ assetPath: String) -> URL? {
        let components = assetPath.split(separator: "/").map(String.init)
        guard let fileName = components.last else { return nil }
        let name = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        guard !name.isEmpty, !ext.isEmpty else { return nil }
        let directories = components.dropLast()

        if let directory = directories.first,
           let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: directory) {
            return url
        }
        return Bundle.main.url(forResource: name, withExtension: ext)
    }

    private func readBundledText(assetPath: String) throws -> String {
        if let url = bundledURL(assetPath), let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        throw PortalError.invalidSchoolDefinition
    }

    private func readJSONObject(assetPath: String) -> [String: Any]? {
        if let remote = remoteFile(assetPath: assetPath),
           let text = try? String(contentsOf: remote, encoding: .utf8),
           let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           (try? validateDefinition(object)) != nil {
            return object
        }
        guard let url = bundledURL(assetPath),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func readConfiguredText(assetPath: String) -> String? {
        if let remote = remoteFile(assetPath: assetPath),
           let text = try? String(contentsOf: remote, encoding: .utf8) {
            return text
        }
        if let url = bundledURL(assetPath), let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return nil
    }

    private func remoteCacheRoot() throws -> URL {
        let documents = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return documents.appendingPathComponent(Self.remoteCacheDirectory, isDirectory: true)
    }

    private func remoteFile(assetPath: String) -> URL? {
        guard let root = try? remoteCacheRoot() else { return nil }
        return root.appendingPathComponent(assetPath)
    }

    /// Port of `SchoolAdapterRepository.writeRemoteFile`: writes atomically and refuses to escape
    /// the cache root.
    private func writeRemoteFile(cacheRoot: URL, assetPath: String, content: String) throws {
        let target = cacheRoot.appendingPathComponent(assetPath)
        let rootPath = cacheRoot.standardizedFileURL.path
        guard target.standardizedFileURL.path.hasPrefix(rootPath) else {
            throw PortalError.invalidSchoolDefinition
        }
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = target.appendingPathExtension("tmp")
        try content.write(to: temporary, atomically: true, encoding: .utf8)
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        do {
            try fileManager.moveItem(at: temporary, to: target)
        } catch {
            try content.write(to: target, atomically: true, encoding: .utf8)
            try? fileManager.removeItem(at: temporary)
        }
    }
}

/// Port of `PalmAcademicGitHub.repositoryFile`.
enum GitHubRepository {
    private static let owner = "Genkaim"
    private static let repository = "palm-academic"
    private static let branch = "main"

    static func repositoryFile(_ path: String) async throws -> String {
        let encodedPath = path.split(separator: "/").map(String.init).joined(separator: "/")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let urlString = "https://raw.githubusercontent.com/\(owner)/\(repository)/\(branch)/\(encodedPath)"
        guard let url = URL(string: urlString) else { throw PortalError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PortalError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw PortalError.invalidResponse
        }
        return text
    }

    static func latestRelease() async throws -> GitHubRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest") else {
            throw PortalError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PortalError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let htmlUrl: String
    let publishedAt: String?
    let body: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlUrl = "html_url"
        case publishedAt = "published_at"
        case body
    }
}