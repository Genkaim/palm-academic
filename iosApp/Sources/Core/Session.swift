import CryptoKit
import Foundation
import Security
import WebKit

/// Persists the EAMS session cookie across process restarts, mirroring `PortalSessionStore`.
///
/// Android can hand cookies to a system WebView via CookieManager. On iOS the equivalent durable
/// store is `HTTPCookieStorage`, so the persisted header is replayed into it on launch.
///
/// Main-actor isolated because cookie bookkeeping reads the selected school origin.
@MainActor
final class SessionStore {
    static let shared = SessionStore()

    private let cookieHeaderKey = "academic_session_cookie_header"
    private let lock = NSLock()
    private var pendingWebKitClear: Task<Void, Never>?
    private var clearRevision = 0

    private init() {}

    var persistedCookieHeader: String? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = UserDefaults.standard.string(forKey: cookieHeaderKey),
              !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    var hasPersistedSession: Bool {
        guard let header = persistedCookieHeader else { return false }
        let accepted = SchoolCatalog.shared.definition?.auth?.resolvedCookieNames ?? ["SESSION"]
        if accepted.isEmpty { return true }
        let names = header.split(separator: ";").compactMap { part -> String? in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: "=") else { return nil }
            return String(trimmed[..<separator])
        }
        return names.contains { name in accepted.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
    }

    func saveCookieHeader(_ header: String) {
        guard !header.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        lock.lock()
        UserDefaults.standard.set(header, forKey: cookieHeaderKey)
        lock.unlock()
    }

    /// Port of `PortalSessionStore.mergeCookies`: `nil` removes a cookie.
    func mergeCookies(_ values: [String: String?]) {
        guard !values.isEmpty else { return }
        var cookies: [String: String] = [:]
        var order: [String] = []
        if let header = persistedCookieHeader {
            for part in header.split(separator: ";") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                guard let separator = trimmed.firstIndex(of: "=") else { continue }
                let name = String(trimmed[trimmed.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    if cookies[name] == nil { order.append(name) }
                    cookies[name] = value
                }
            }
        }
        for (name, value) in values {
            if let value {
                if cookies[name] == nil { order.append(name) }
                cookies[name] = value
            } else if cookies[name] != nil {
                cookies[name] = nil
            }
        }
        let header = order.compactMap { name -> String? in
            guard let value = cookies[name] else { return nil }
            return "\(name)=\(value)"
        }.joined(separator: "; ")
        if !header.isEmpty { saveCookieHeader(header) }
    }

    /// Replays the persisted cookie into `HTTPCookieStorage` so WKWebView shares the session.
    @discardableResult
    func restoreToCookieStorage() -> Bool {
        guard let header = persistedCookieHeader else { return false }
        let pairs = header.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("=") }
        guard !pairs.isEmpty else { return false }

        let storage = HTTPCookieStorage.shared
        let origin = SchoolCatalog.shared.origin
        let host = SchoolCatalog.shared.definition?.auth?.resolvedCookieHosts.first
            ?? URL(string: origin)?.host ?? ""
        let path = SchoolCatalog.shared.definition?.auth?.resolvedCookieHosts.isEmpty == false ? "/" : "/student"
        for pair in pairs {
            guard let separator = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[pair.startIndex..<separator])
            let value = String(pair[pair.index(after: separator)...])
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: host,
                .path: path
            ]
            if origin.hasPrefix("https://") {
                properties[.secure] = "TRUE"
            }
            if let cookie = HTTPCookie(properties: properties) {
                storage.setCookie(cookie)
            }
        }
        return true
    }

    /// Captures the current WKWebView cookie state after a navigation.
    ///
    /// Mirrors `PortalSessionStore.captureFromWebView`. The reading path is `WKHTTPCookieStore`,
    /// not `HTTPCookieStorage`: a real EAMS WebView populates the WebKit store, and that copy is
    /// what the server will accept on the next request.
    /// Captures the WebKit cookie jar after a successful web login.
    ///
    /// - Returns: `false` when no school-domain cookies -- in particular no SESSION cookie --
    ///   were available, so callers can distinguish "login really finished" from "the portal
    ///   rendered a non-login page without issuing a session".
    @discardableResult
    func captureFromWebView(
        cookieHosts: [String]? = nil,
        acceptedCookieNames: [String]? = nil
    ) async -> Bool {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        guard !cookies.isEmpty else { return false }
        let configuredHosts = cookieHosts
            ?? SchoolCatalog.shared.definition?.auth?.resolvedCookieHosts
            ?? []
        let hosts = configuredHosts.isEmpty
            ? [URL(string: SchoolCatalog.shared.origin)?.host ?? ""]
            : configuredHosts
        let filtered = cookies.filter { cookie in
            let cookieDomain = cookie.domain
            let normalised = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain
            return hosts.contains { host in
                normalised == host || host.hasSuffix("." + normalised)
            }
        }
        guard !filtered.isEmpty else { return false }
        // A session has to actually carry SESSION; a page of public marketing markup served from
        // the same host would otherwise be captured as "logged in".
        let names = acceptedCookieNames
            ?? SchoolCatalog.shared.definition?.auth?.resolvedCookieNames
            ?? ["SESSION"]
        let hasSession = names.isEmpty || filtered.contains { cookie in
            !cookie.value.isEmpty && names.contains { $0.caseInsensitiveCompare(cookie.name) == .orderedSame }
        }
        guard hasSession else { return false }
        let header = filtered
            .sorted(by: { $0.name < $1.name })
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        saveCookieHeader(header)
        // Make URLSession requests see the same cookies immediately, mirroring
        // `WebViewCookieJar.loadForRequest` which merges persisted and live cookies per request.
        restoreToCookieStorage()
        return true
    }

    /// Installs the persisted cookies into the WebView's own cookie store, mirroring
    /// `PortalSessionStore.restoreToWebView`. The completion runs once every cookie has been
    /// accepted by `WKHTTPCookieStore`; the WebView must not `load` until then or the portal
    /// will answer with a fresh login redirect.
    @discardableResult
    func restoreToWebView(completion: (() -> Void)? = nil) -> Bool {
        guard let header = persistedCookieHeader else {
            completion?()
            return false
        }
        let pairs = header.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("=") }
        guard !pairs.isEmpty else {
            completion?()
            return false
        }
        let configuredHosts = SchoolCatalog.shared.definition?.auth?.resolvedCookieHosts ?? []
        let host = configuredHosts.first ?? URL(string: SchoolCatalog.shared.origin)?.host ?? ""
        let isSecure = true
        let path = configuredHosts.isEmpty ? "/student" : "/"
        let cookies: [HTTPCookie] = pairs.compactMap { pair in
            guard let sep = pair.firstIndex(of: "=") else { return nil }
            let name = String(pair[pair.startIndex..<sep])
            let value = String(pair[pair.index(after: sep)...])
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: host,
                .path: path
            ]
            if isSecure { properties[.secure] = "TRUE" }
            if name.uppercased() == "SESSION" {
                properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            }
            return HTTPCookie(properties: properties)
        }
        guard !cookies.isEmpty else {
            completion?()
            return false
        }
        let store = WKWebsiteDataStore.default().httpCookieStore
        // Fast path: skip the writes when the WebView already has the exact cookies we want.
        store.getAllCookies { [weak self] existing in
            let alreadyInstalled = cookies.allSatisfy { cookie in
                existing.contains { existingCookie in
                    existingCookie.name == cookie.name &&
                    existingCookie.value == cookie.value &&
                    (existingCookie.domain == cookie.domain ||
                        existingCookie.domain == "." + cookie.domain)
                }
            }
            if alreadyInstalled {
                Task { @MainActor in completion?() }
                return
            }
            let group = DispatchGroup()
            for cookie in cookies {
                group.enter()
                store.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main) {
                Task { @MainActor in
                    self?.saveCookieHeader(
                        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    )
                    completion?()
                }
            }
        }
        return true
    }

    /// Async form of `restoreToWebView`, mirroring `PortalSessionStore.restoreToWebViewAndWait`.
    @discardableResult
    func restoreToWebViewAndWait() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let started = restoreToWebView {
                continuation.resume(returning: true)
            }
            if !started {
                continuation.resume(returning: false)
            }
        }
    }

    func clear() {
        lock.lock()
        UserDefaults.standard.removeObject(forKey: cookieHeaderKey)
        lock.unlock()
        let configuredHosts = SchoolCatalog.shared.definition?.auth?.resolvedCookieHosts ?? []
        let originHost = URL(string: SchoolCatalog.shared.origin)?.host.map { [$0] } ?? []
        let hosts = Set((configuredHosts + originHost).map { $0.lowercased() })
        if !hosts.isEmpty {
            // `cookies(for: origin)` only returns cookies whose path matches `/`; EAMS normally
            // scopes SESSION to `/student`, so that lookup left the very cookie we meant to clear.
            // Match by domain here and remove every path variant for the selected school.
            let storage = HTTPCookieStorage.shared
            storage.cookies?.filter { cookie in
                let domain = cookie.domain
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    .lowercased()
                return hosts.contains { host in host == domain || host.hasSuffix(".\(domain)") }
            }.forEach(storage.deleteCookie)
        }
        // The WebKit data store owns a separate copy of the cookies used by the reader
        // web view, so it has to be cleared alongside HTTPCookieStorage. The callback
        // form is used because the async overload is unavailable on iOS 16.
        let previous = pendingWebKitClear
        clearRevision &+= 1
        let revision = clearRevision
        pendingWebKitClear = Task { @MainActor in
            if let previous { await previous.value }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                WKWebsiteDataStore.default().removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                    modifiedSince: .distantPast
                ) {
                    continuation.resume()
                }
            }
            // A later clear owns the stored task; do not erase its handle when this one completes.
            if revision == clearRevision { pendingWebKitClear = nil }
        }
    }

    /// Serialises a new login behind logout's asynchronous WebKit deletion. Without this barrier,
    /// a fast user can finish the new login first and then have the old deletion callback erase the
    /// freshly-installed SESSION cookie.
    func waitForPendingClear() async {
        let revision = clearRevision
        let pending = pendingWebKitClear
        await pending?.value
        if revision == clearRevision { pendingWebKitClear = nil }
    }
}

enum SessionValidation {
    case valid
    case expired
    case unavailable
}

/// Port of `AuthRepository` from `AuthRepository.kt`.
///
/// Main-actor isolated because persisting and restoring the session goes through
/// `SessionStore`, which is main-actor isolated.
@MainActor
struct AuthRepository {
    private let session: URLSession

    init(session: URLSession = PortalHTTP.session) {
        self.session = session
    }

    private var origin: String { SchoolCatalog.shared.origin }
    private var baseURL: String { SchoolCatalog.shared.baseURL }
    private var loginURL: String { "\(baseURL)/login" }
    private var homeURL: String {
        SchoolCatalog.shared.definition?.auth?.resolvedSuccessPrefixes.first ?? "\(baseURL)/home"
    }

    /// Port of `AuthRepository.login`.
    ///
    /// The salt, login and cookie persistence all happen inside one continuous `URLSession`
    /// cookie context. Splitting them allows the server to see a request without the pre-session
    /// cookie and answer with a captcha challenge instead of accepting valid credentials.
    func login(username: String, password: String) async throws {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else { throw PortalError.loginRejected("请输入账号和密码") }

        // Logout clears WebKit asynchronously. Wait for it before any new cookie is created, or its
        // completion can erase the successful login after this method returns.
        await SessionStore.shared.waitForPendingClear()

        // A dedicated client and an in-memory cookie jar keep the login handshake isolated from the
        // cached global session, matching Android's LoginCookieJar.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 40
        let client = URLSession(configuration: configuration)
        let loginCookies = LoginCookieJar()

        // 通用登录引擎：学校定义自己描述整个握手（请求/提取/加密/判定），App 只负责执行，
        // 与 Android `AuthRepository.login` 的 engine 分支一一对应。
        if let auth = SchoolCatalog.shared.definition?.auth, auth.usesEngine, let engine = auth.engine {
            try await loginWithEngine(engine, username: trimmed, password: password, auth: auth, cookies: loginCookies)
            SessionStore.shared.saveCookieHeader(loginCookies.header)
            SessionStore.shared.restoreToCookieStorage()
            let installed = await SessionStore.shared.restoreToWebViewAndWait()
            if !installed { throw PortalError.webViewSessionMissing }
            return
        }

        // Prime the pre-session cookie. Real EAMS deployments reject a correct password when the
        // login page has never been opened in the same session.
        var pageRequest = URLRequest(url: URL(string: loginURL)!)
        pageRequest.httpMethod = "GET"
        pageRequest.setValue(homeURL, forHTTPHeaderField: "Referer")
        pageRequest.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        pageRequest.setValue(Self.languageHeader, forHTTPHeaderField: "Accept-Language")
        _ = try await perform(client, pageRequest, cookies: loginCookies)

        var saltRequest = URLRequest(url: URL(string: "\(baseURL)/login-salt")!)
        applyAjaxHeaders(&saltRequest, referer: loginURL)
        let saltData = try await perform(client, saltRequest, cookies: loginCookies)
        guard let salt = String(data: saltData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
              !salt.isEmpty else {
            throw PortalError.emptySalt
        }

        var loginRequest = URLRequest(url: URL(string: loginURL)!)
        applyAjaxHeaders(&loginRequest, referer: loginURL)
        loginRequest.httpMethod = "POST"
        loginRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        loginRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        loginRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": trimmed,
            "password": Self.sha1Hex("\(salt)-\(password)"),
            "captchaToken": ""
        ])
        let responseData = try await perform(client, loginRequest, cookies: loginCookies)

        // Only an explicit captcha demand or a negative `result` counts as a credential failure.
        // Some deployments answer a successful login with an empty body or HTML, so a missing
        // `result` must never be read as a rejection.
        if let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
            if (object["needCaptcha"] as? Bool) == true {
                throw PortalError.loginRejected("教务系统要求安全验证，请改用网页登录完成验证")
            }
            if object["result"] != nil, (object["result"] as? Bool) != true {
                throw PortalError.loginRejected((object["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "账号或密码错误")
            }
        }

        guard loginCookies.hasSession else {
            throw PortalError.noSession
        }
        // The login endpoint accepted the request, so persist the session immediately. Home page
        // structure detection is content reading and must not invalidate a completed login.
        SessionStore.shared.saveCookieHeader(loginCookies.header)
        SessionStore.shared.restoreToCookieStorage()
        // Mirror Android: install the cookies into the WebView's own store before declaring the
        // login successful. Without this, the first page navigation bounces off a login redirect
        // and reports "登录已过期" immediately.
        let installed = await SessionStore.shared.restoreToWebViewAndWait()
        if !installed {
            throw PortalError.webViewSessionMissing
        }
    }

    /// Port of `AuthRepository.validateSession`.
    func validateSession() async -> SessionValidation {
        guard SessionStore.shared.hasPersistedSession else { return .expired }
        // Replay the durable cookie header into HTTPCookieStorage so the URLSession probe sees
        // the SESSION cookie even when the persisted header was captured by `WebLoginView` and
        // only lives in the WebKit store.
        SessionStore.shared.restoreToCookieStorage()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
        // Keep the probe short so a campus network that is unreachable does not stall launch.
        configuration.timeoutIntervalForRequest = 12
        let client = URLSession(configuration: configuration)

        do {
            var request = URLRequest(url: URL(string: homeURL)!)
            request.httpMethod = "GET"
            let (data, response) = try await client.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            let html = String(data: data, encoding: .utf8) ?? ""
            let finalURL = http.url?.absoluteString ?? homeURL
            if Self.isLoginPage(html, finalURL: finalURL) { return .expired }
            if (200..<400).contains(http.statusCode) { return .valid }
            if http.statusCode == 401 || http.statusCode == 403 { return .expired }
            return .unavailable
        } catch {
            return .unavailable
        }
    }

    /// Port of `AuthRepository.isLoginPage`.
    ///
    /// Pure string inspection, so it is deliberately left outside the main actor: the
    /// web view bridge calls it from a nonisolated delegate context.
    nonisolated static func isLoginPage(_ content: String, finalURL: String = "") -> Bool {
        var path = finalURL.split(separator: "?").first.map(String.init) ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/login") { return true }
        if content.contains("<title>登入页面</title>") { return true }
        return content.contains("id=\"vue_main\"") && content.contains("login-salt")
    }

    private static let languageHeader = "zh-CN,zh;q=0.9"

    private func applyAjaxHeaders(_ request: inout URLRequest, referer: String) {
        request.httpMethod = "GET"
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(Self.languageHeader, forHTTPHeaderField: "Accept-Language")
    }

    private func perform(
        _ client: URLSession,
        _ originalRequest: URLRequest,
        cookies: LoginCookieJar
    ) async throws -> Data {
        var request = originalRequest
        cookies.apply(to: &request)
        let (data, response) = try await client.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PortalError.invalidResponse }
        cookies.capture(from: http, fallbackURL: request.url)
        guard (200..<400).contains(http.statusCode) else { throw PortalError.requestFailed(http.statusCode) }
        return data
    }

    static func sha1Hex(_ value: String) -> String {
        Insecure.SHA1.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func md5Hex(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// RSA/PKCS1 encryption with an X.509 SubjectPublicKeyInfo key in Base64 -- the counterpart of
    /// Android's `Cipher.getInstance("RSA/ECB/PKCS1Padding")`, for CAS deployments that encrypt the
    /// password client-side.
    static func rsaEncryptBase64(_ plain: String, publicKeyBase64: String) throws -> String {
        guard let keyData = Data(base64Encoded: publicKeyBase64) else {
            throw PortalError.engineFailed("RSA 公钥不是有效的 Base64")
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) else {
            throw PortalError.engineFailed("RSA 公钥无法解析")
        }
        guard SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionPKCS1),
              let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, Data(plain.utf8) as CFData, &error) else {
            throw PortalError.engineFailed("密码加密失败")
        }
        return (encrypted as Data).base64EncodedString()
    }

    // MARK: - 通用登录引擎

    /// Port of `AuthRepository.loginWithEngine`: the school definition describes the whole
    /// handshake and the app only executes it. Network errors propagate unchanged so the caller
    /// keeps retrying; only a captcha/rejected rule match throws `PortalError.loginRejected`.
    private func loginWithEngine(
        _ engine: SchoolDefinition.AuthEnginePayload,
        username: String,
        password: String,
        auth: SchoolDefinition.AuthPayload,
        cookies: LoginCookieJar
    ) async throws {
        // URLSession's automatic redirect following hides the intermediate responses, so a 302's
        // `Set-Cookie` headers -- exactly where CAS puts its ticket-granting cookie -- would never
        // reach the jar. The engine declines every redirect and re-issues the request itself.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 40
        let client = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { client.finishTasksAndInvalidate() }

        var variables: [String: String] = [
            "username": username,
            "password": password,
            "baseUrl": SchoolCatalog.shared.definition?.baseUrl ?? baseURL,
            "loginUrl": auth.loginUrl ?? ""
        ]
        var stepResponses: [String: EngineResponse] = [:]
        var lastResponse: EngineResponse?

        for (index, step) in engine.steps.enumerated() {
            let id = step.id.flatMap { $0.isEmpty ? nil : $0 } ?? "step\(index)"
            if let spec = step.request {
                let response = try await performEngineRequest(spec, variables: variables, client: client, cookies: cookies)
                stepResponses[id] = response
                lastResponse = response
            } else if let spec = step.extract {
                let source: EngineResponse
                if let from = spec.from, !from.isEmpty {
                    guard let referenced = stepResponses[from] else {
                        throw PortalError.engineFailed("提取步骤 '\(id)' 引用了不存在的请求步骤 '\(from)'")
                    }
                    source = referenced
                } else {
                    guard let last = lastResponse else {
                        throw PortalError.engineFailed("提取步骤 '\(id)' 之前没有任何请求步骤")
                    }
                    source = last
                }
                guard let regex = try? NSRegularExpression(
                    pattern: spec.regex,
                    options: [.dotMatchesLineSeparators, .caseInsensitive]
                ) else { throw PortalError.engineFailed("提取步骤 '\(id)' 的正则表达式无效") }
                let group = spec.group ?? 1
                let range = NSRange(source.body.startIndex..., in: source.body)
                guard let match = regex.firstMatch(in: source.body, range: range),
                      group < match.numberOfRanges,
                      let valueRange = Range(match.range(at: group), in: source.body) else {
                    throw PortalError.engineFailed("提取步骤 '\(id)' 未匹配到内容")
                }
                variables[id] = String(source.body[valueRange])
            } else if let spec = step.transform {
                let input = interpolate(spec.input ?? "", variables: variables)
                switch spec.algorithm {
                case "rsa-pkcs1-base64":
                    guard let publicKey = spec.publicKey, !publicKey.isEmpty else {
                        throw PortalError.engineFailed("变换步骤 '\(id)' 缺少 RSA 公钥")
                    }
                    variables[id] = try Self.rsaEncryptBase64(input, publicKeyBase64: publicKey)
                case "sha1":
                    variables[id] = Self.sha1Hex(input)
                case "md5":
                    variables[id] = Self.md5Hex(input)
                default:
                    throw PortalError.engineFailed("不支持的变换算法: \(spec.algorithm)")
                }
            }
        }

        try judgeEngineOutcome(engine.outcome, lastResponse: lastResponse, auth: auth, cookies: cookies)
    }

    private func performEngineRequest(
        _ spec: SchoolDefinition.AuthEnginePayload.Step.Request,
        variables: [String: String],
        client: URLSession,
        cookies: LoginCookieJar
    ) async throws -> EngineResponse {
        guard let initialURL = URL(string: interpolate(spec.url, variables: variables)) else {
            throw PortalError.invalidResponse
        }
        var currentURL = initialURL
        var method = (spec.method ?? "GET").uppercased()
        var body = try engineBody(spec, variables: variables)
        var redirectCount = 0

        while true {
            var request = URLRequest(url: currentURL)
            request.httpMethod = method
            if let body, method != "GET", method != "HEAD" {
                request.httpBody = body.data
                request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
            }
            spec.headers?.forEach { key, value in
                request.setValue(interpolate(value, variables: variables), forHTTPHeaderField: key)
            }
            cookies.apply(to: &request)

            let (data, response) = try await client.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw PortalError.invalidResponse }
            cookies.capture(from: http, fallbackURL: currentURL)

            if (300..<400).contains(http.statusCode),
               let location = http.value(forHTTPHeaderField: "Location"),
               redirectCount < 10,
               let nextURL = URL(string: location, relativeTo: currentURL)?.absoluteURL {
                // A redirect drops the body and switches to GET, like a browser after a form POST.
                redirectCount += 1
                currentURL = nextURL
                method = "GET"
                body = nil
                continue
            }
            return EngineResponse(
                code: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "",
                finalURL: http.url?.absoluteString ?? currentURL.absoluteString
            )
        }
    }

    private func judgeEngineOutcome(
        _ outcome: SchoolDefinition.AuthEnginePayload.Outcome?,
        lastResponse: EngineResponse?,
        auth: SchoolDefinition.AuthPayload,
        cookies: LoginCookieJar
    ) throws {
        guard let response = lastResponse else {
            throw PortalError.engineFailed("登录引擎没有执行任何请求步骤")
        }

        func matches(_ rule: SchoolDefinition.AuthEnginePayload.Outcome.Rule?) -> Bool {
            guard let rule else { return false }
            if let codes = rule.statusCodes, !codes.contains(response.code) { return false }
            if let needles = rule.bodyContains,
               !needles.contains(where: { response.body.range(of: $0, options: .caseInsensitive) != nil }) {
                return false
            }
            return true
        }

        if matches(outcome?.captcha) {
            let message = outcome?.captcha?.message.flatMap { $0.isEmpty ? nil : $0 }
            throw PortalError.loginRejected(message ?? "教务系统要求安全验证，请改用网页登录完成验证")
        }
        if matches(outcome?.rejected) {
            let message = outcome?.rejected?.message.flatMap { $0.isEmpty ? nil : $0 }
            throw PortalError.loginRejected(message ?? "账号或密码错误")
        }

        let success = outcome?.success
        let prefixes = success?.finalUrlPrefixes ?? auth.resolvedSuccessPrefixes
        let cookieNames = success?.cookies ?? auth.resolvedCookieNames
        let statusCodes = success?.statusCodes ?? []
        let urlOK = prefixes.isEmpty || prefixes.contains(where: { response.finalURL.hasPrefix($0) })
        let cookiesOK = cookies.hasAnyCookie(cookieNames)
        let statusOK = statusCodes.isEmpty || statusCodes.contains(response.code)
        guard urlOK, cookiesOK, statusOK else {
            throw PortalError.engineFailed("登录请求已完成，但未确认登录成功，请重试")
        }
    }

    private func engineBody(
        _ spec: SchoolDefinition.AuthEnginePayload.Step.Request,
        variables: [String: String]
    ) throws -> EngineBody? {
        switch spec.contentType {
        case "form":
            // Everything outside the unreserved set is percent-encoded, which matters for an RSA
            // ciphertext: a raw "+" in Base64 would decode as a space on the server.
            let pairs = (spec.form ?? [:]).map { key, value -> String in
                let escapedKey = key.addingPercentEncoding(withAllowedCharacters: Self.formAllowedCharacters) ?? key
                let escapedValue = interpolate(value, variables: variables)
                    .addingPercentEncoding(withAllowedCharacters: Self.formAllowedCharacters) ?? ""
                return "\(escapedKey)=\(escapedValue)"
            }
            return EngineBody(
                data: Data(pairs.sorted().joined(separator: "&").utf8),
                contentType: "application/x-www-form-urlencoded"
            )
        case "json":
            var object: [String: Any] = [:]
            for (key, value) in spec.json ?? [:] {
                object[key] = interpolate(value, variables: variables)
            }
            return EngineBody(
                data: try JSONSerialization.data(withJSONObject: object),
                contentType: "application/json; charset=utf-8"
            )
        default:
            guard let raw = spec.body else { return nil }
            return EngineBody(
                data: Data(interpolate(raw, variables: variables).utf8),
                contentType: "text/plain; charset=utf-8"
            )
        }
    }

    private func interpolate(_ template: String, variables: [String: String]) -> String {
        var result = template
        for (key, value) in variables {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }

    private static let formAllowedCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private struct EngineResponse {
        let code: Int
        let body: String
        let finalURL: String
    }

    private struct EngineBody {
        let data: Data
        let contentType: String
    }
}

/// Lets the login engine follow redirects by hand: every redirect is declined so the loop in
/// `performEngineRequest` can capture each hop's `Set-Cookie` headers and re-issue the request.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// One-login-only cookie jar. It deliberately never reads `HTTPCookieStorage.shared`, so an expired
/// SESSION cannot contaminate the pre-session cookie, salt request or credential POST.
@MainActor
private final class LoginCookieJar {
    private var values: [String: HTTPCookie] = [:]

    var hasSession: Bool {
        values.values.contains { $0.name.uppercased() == "SESSION" && !$0.value.isEmpty }
    }

    func hasAnyCookie(_ names: [String]) -> Bool {
        names.isEmpty || values.values.contains { cookie in
            !cookie.value.isEmpty && names.contains { $0.caseInsensitiveCompare(cookie.name) == .orderedSame }
        }
    }

    var header: String {
        values.values
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    func apply(to request: inout URLRequest) {
        guard !values.isEmpty else { return }
        HTTPCookie.requestHeaderFields(with: Array(values.values)).forEach {
            request.setValue($0.value, forHTTPHeaderField: $0.key)
        }
    }

    func capture(from response: HTTPURLResponse, fallbackURL: URL?) {
        guard let url = response.url ?? fallbackURL else { return }
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String else { return }
            result[key] = String(describing: entry.value)
        }
        HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).forEach { cookie in
            let key = "\(cookie.domain)|\(cookie.path)|\(cookie.name)"
            if cookie.expiresDate.map({ $0 <= Date() }) == true {
                values.removeValue(forKey: key)
            } else {
                values[key] = cookie
            }
        }
    }
}

/// Port of `PortalHttp`. Cookie handling mirrors `WebViewCookieJar`.
enum PortalHTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 40
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Port of `PortalHttp.hasSessionCookie`: the app-private copy is the durable cold-start signal.
    @MainActor
    static var hasSessionCookie: Bool { SessionStore.shared.hasPersistedSession }
}
