import Foundation

struct LocalRuleImportConflict: LocalizedError {
    let schoolID: String
    let existingName: String
    let replacementName: String
    let existingIsImported: Bool

    var errorDescription: String? { "学校 id \(schoolID) 已存在" }
}

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
    private static let localCacheDirectory = "local-school-adapters"
    private static let localIndexFile = "local-imports.json"
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

    func authorInfo(for schoolID: String) -> SchoolAuthorInfo? {
        guard let profile = profiles.first(where: { $0.id == schoolID }),
              let root = readJSONObject(assetPath: profile.definitionAsset),
              let author = root["author"] as? [String: Any] else { return nil }
        return SchoolAuthorInfo(
            schoolID: profile.id,
            schoolName: profile.name,
            authorName: ((author["name"] as? String)?.isEmpty == false)
                ? (author["name"] as! String) : "未知",
            contact: ((author["email"] as? String)?.isEmpty == false)
                ? (author["email"] as! String) : "未提供",
            isImported: profile.isImported
        )
    }

    /// Imports two user-selected files into an app-owned store that cloud refresh never touches.
    @discardableResult
    func importLocalSchool(
        definitionData: Data,
        adapterData: Data,
        overwriteExisting: Bool = false
    ) throws -> SchoolProfile {
        guard definitionData.count <= 1_048_576 else {
            throw localImportError("规则 JSON 不能超过 1 MB")
        }
        guard adapterData.count <= 5_242_880,
              let adapterText = String(data: adapterData, encoding: .utf8),
              !adapterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              adapterText.contains("PalmAcademicAdapter") else {
            throw localImportError("适配器 JS 无效或超过 5 MB")
        }
        guard var root = try JSONSerialization.jsonObject(with: definitionData) as? [String: Any] else {
            throw PortalError.invalidSchoolDefinition
        }
        try validateDefinition(root)
        guard let id = root["id"] as? String,
              id.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else {
            throw localImportError("学校 id 只能包含小写字母、数字和连字符")
        }
        guard let name = root["name"] as? String, !name.isEmpty,
              let baseURL = root["baseUrl"] as? String,
              var components = URLComponents(string: baseURL),
              components.scheme == "https", components.host != nil else {
            throw PortalError.invalidSchoolDefinition
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let origin = components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
            throw PortalError.invalidSchoolDefinition
        }
        if let existing = profiles.first(where: { $0.id == id }), !overwriteExisting {
            throw LocalRuleImportConflict(
                schoolID: id,
                existingName: existing.name,
                replacementName: name,
                existingIsImported: existing.isImported
            )
        }
        let definitionAsset = "schools/local/\(id).json"
        let adapterAsset = "adapters/local/\(id)-reader.js"
        root["readerAdapter"] = adapterAsset

        let readerConfig: SchoolProfile.ReaderConfig
        if let raw = root["readerConfig"],
           let data = try? JSONSerialization.data(withJSONObject: raw),
           let decoded = try? JSONDecoder().decode(SchoolProfile.ReaderConfig.self, from: data) {
            readerConfig = decoded
        } else {
            readerConfig = .init(scheduleProfiles: [])
        }
        let profile = SchoolProfile(
            id: id,
            name: name,
            origin: origin,
            definitionAsset: definitionAsset,
            readerConfig: readerConfig,
            isImported: true
        )
        let definitionOutput = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        guard let definitionText = String(data: definitionOutput, encoding: .utf8) else {
            throw PortalError.invalidSchoolDefinition
        }
        let cacheRoot = try localCacheRoot()
        try writeLocalFile(cacheRoot: cacheRoot, assetPath: definitionAsset, content: definitionText)
        try writeLocalFile(cacheRoot: cacheRoot, assetPath: adapterAsset, content: adapterText)
        try writeLocalIndex(readLocalProfiles().filter { $0.id != id } + [profile])
        profiles = try readProfiles()
        cachedDefinition = nil
        definition = nil
        adapterScriptCache.removeAll()
        return profile
    }

    /// Deletes only app-owned imports. Bundled and downloaded profiles remain read-only.
    @discardableResult
    func deleteLocalSchool(id: String) throws -> String {
        guard let profile = profiles.first(where: { $0.id == id && $0.isImported }) else {
            throw localImportError("只能删除本地导入的学校")
        }
        try writeLocalIndex(readLocalProfiles().filter { $0.id != id })
        try? fileManager.removeItem(at: localFile(assetPath: profile.definitionAsset))
        try? fileManager.removeItem(at: localFile(assetPath: "adapters/local/\(id)-reader.js"))
        profiles = try readProfiles()
        if selectedSchoolID == id && !profiles.contains(where: { $0.id == id }) {
            selectedSchoolID = profiles.first { $0.id == Self.defaultSchoolID }?.id
                ?? profiles.first?.id
                ?? Self.defaultSchoolID
            UserDefaults.standard.set(selectedSchoolID, forKey: Self.selectedSchoolKey)
            NotificationPreferences.shared.clearSnapshots()
        }
        cachedDefinition = nil
        definition = nil
        adapterScriptCache.removeAll()
        return selectedSchoolID
    }

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
        definition = nil
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
            // `profiles` can be empty if a refresh wrote an unusable overlay; indexing [0] here
            // crashed the app. Fall back to the hard-coded default id until profiles recover.
            selectedSchoolID = profiles.first { $0.id == SchoolCatalog.defaultSchoolID }?.id
                ?? profiles.first?.id
                ?? SchoolCatalog.defaultSchoolID
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
            let builtIn = bundled.configVersion > cachedIndex.configVersion ? bundled.builtIn : cachedIndex.builtIn
            return mergeWithLocalProfiles(builtIn)
        }
        return mergeWithLocalProfiles(bundled.builtIn)
    }

    private func mergeWithLocalProfiles(_ builtIn: [SchoolProfile]) -> [SchoolProfile] {
        let local = readLocalProfiles()
        let localIDs = Set(local.map(\.id))
        // A local import is an explicit user override. Deleting it reveals the bundled/cloud
        // profile with the same id again without mutating that managed source.
        return local + builtIn.filter { !localIDs.contains($0.id) }
    }

    private func readLocalProfiles() -> [SchoolProfile] {
        guard let data = try? Data(contentsOf: localFile(assetPath: Self.localIndexFile)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["schemaVersion"] as? Int) == 1,
              let rawProfiles = root["schools"] as? [[String: Any]] else { return [] }
        return rawProfiles.compactMap { try? SchoolProfile(fromJSONObject: $0, isImported: true) }
    }

    private func writeLocalIndex(_ localProfiles: [SchoolProfile]) throws {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "schools": localProfiles.map(profileJSONObject)
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw PortalError.invalidSchoolDefinition
        }
        try writeLocalFile(cacheRoot: localCacheRoot(), assetPath: Self.localIndexFile, content: text)
    }

    private func profileJSONObject(_ profile: SchoolProfile) -> [String: Any] {
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
        if let auth = root["auth"] as? [String: Any] {
            let type = auth["type"] as? String ?? "salted-sha1"
            guard type == "salted-sha1" || type == "web" || type == "engine" else {
                throw PortalError.invalidSchoolDefinition
            }
            if let captcha = auth["captcha"] as? [String: Any],
               (captcha["required"] as? Bool) == true {
                guard let imageURL = captcha["imageUrl"] as? String,
                      imageURL.hasPrefix("https://") else {
                    throw PortalError.invalidSchoolDefinition
                }
                if let parameter = captcha["refreshQueryParameter"] as? String,
                   parameter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw PortalError.invalidSchoolDefinition
                }
            }
            if type == "engine" {
                // Mirrors Android `validateDefinition`: every engine step must be exactly one of
                // request / extract / transform, carrying the fields its kind requires.
                guard let engine = auth["engine"] as? [String: Any],
                      let steps = engine["steps"] as? [[String: Any]], !steps.isEmpty else {
                    throw PortalError.invalidSchoolDefinition
                }
                for step in steps {
                    let kinds = [step["request"] != nil, step["extract"] != nil, step["transform"] != nil]
                        .filter { $0 }.count
                    guard kinds == 1 else { throw PortalError.invalidSchoolDefinition }
                    if let request = step["request"] as? [String: Any] {
                        guard let url = request["url"] as? String, !url.isEmpty else {
                            throw PortalError.invalidSchoolDefinition
                        }
                    }
                    if let extract = step["extract"] as? [String: Any] {
                        guard let pattern = extract["regex"] as? String, !pattern.isEmpty,
                              (try? NSRegularExpression(pattern: pattern)) != nil else {
                            throw PortalError.invalidSchoolDefinition
                        }
                    }
                    if let transform = step["transform"] as? [String: Any] {
                        guard let algorithm = transform["algorithm"] as? String,
                              ["rsa-pkcs1-base64", "sha1", "md5"].contains(algorithm) else {
                            throw PortalError.invalidSchoolDefinition
                        }
                    }
                }
                if let outcome = engine["outcome"] as? [String: Any] {
                    // A status code alone is not proof that the password is wrong: gateways and
                    // expired pre-sessions commonly answer 401/403 too. Only a rule carrying an
                    // explicit response-body marker may send the user back to the login form.
                    for key in ["captcha", "rejected"] {
                        guard let rule = outcome[key] as? [String: Any] else { continue }
                        guard let markers = rule["bodyContains"] as? [String],
                              !markers.isEmpty,
                              markers.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                        else { throw PortalError.invalidSchoolDefinition }
                    }
                }
            }
            if type == "web" || type == "engine" {
                guard let loginURL = auth["loginUrl"] as? String,
                      loginURL.hasPrefix("https://"),
                      let prefixes = auth["successUrlPrefixes"] as? [String],
                      !prefixes.isEmpty,
                      prefixes.allSatisfy({ $0.hasPrefix("https://") }) else {
                    throw PortalError.invalidSchoolDefinition
                }
                if let hosts = auth["sessionCookieHosts"] as? [String] {
                    let validHost = try! NSRegularExpression(pattern: "^[A-Za-z0-9.-]+$")
                    guard hosts.allSatisfy({ host in
                        validHost.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)) != nil
                    }) else { throw PortalError.invalidSchoolDefinition }
                }
            }
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
        let local = localFile(assetPath: assetPath)
        if let text = try? String(contentsOf: local, encoding: .utf8),
           let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           (try? validateDefinition(object)) != nil {
            return object
        }
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
        if let text = try? String(contentsOf: localFile(assetPath: assetPath), encoding: .utf8) {
            return text
        }
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

    private func localCacheRoot() throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support.appendingPathComponent(Self.localCacheDirectory, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func localFile(assetPath: String) -> URL {
        let root = (try? localCacheRoot())
            ?? fileManager.temporaryDirectory.appendingPathComponent(Self.localCacheDirectory, isDirectory: true)
        return root.appendingPathComponent(assetPath)
    }

    private func writeLocalFile(cacheRoot: URL, assetPath: String, content: String) throws {
        let target = cacheRoot.appendingPathComponent(assetPath)
        let rootPath = cacheRoot.standardizedFileURL.path
        guard target.standardizedFileURL.path.hasPrefix(rootPath) else {
            throw PortalError.invalidSchoolDefinition
        }
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: target, atomically: true, encoding: .utf8)
    }

    private func localImportError(_ message: String) -> NSError {
        NSError(domain: "PalmAcademic.LocalRule", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
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
