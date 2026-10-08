import CryptoKit
import Foundation
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
        return header.split(separator: ";").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("SESSION=") }
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
        let path = "/student"
        for pair in pairs {
            guard let separator = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[pair.startIndex..<separator])
            let value = String(pair[pair.index(after: separator)...])
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: URL(string: origin)?.host ?? "",
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
    func captureFromWebView() async -> Bool {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        guard !cookies.isEmpty else { return false }
        let host = URL(string: SchoolCatalog.shared.origin)?.host ?? ""
        let filtered = cookies.filter { cookie in
            let cookieDomain = cookie.domain
            let normalised = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain
            return normalised == host || normalised == "." + host || host.hasSuffix("." + normalised)
        }
        guard !filtered.isEmpty else { return false }
        // A session has to actually carry SESSION; a page of public marketing markup served from
        // the same host would otherwise be captured as "logged in".
        let hasSession = filtered.contains { $0.name.uppercased() == "SESSION" && !$0.value.isEmpty }
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
        let host = URL(string: SchoolCatalog.shared.origin)?.host ?? ""
        let isSecure = SchoolCatalog.shared.origin.hasPrefix("https://")
        let path = "/student"
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
        if let origin = URL(string: SchoolCatalog.shared.origin) {
            HTTPCookieStorage.shared.cookies(for: origin)?.forEach(HTTPCookieStorage.shared.deleteCookie)
        }
        // The WebKit data store owns a separate copy of the cookies used by the reader
        // web view, so it has to be cleared alongside HTTPCookieStorage. The callback
        // form is used because the async overload is unavailable on iOS 16.
        let store = WKWebsiteDataStore.default()
        store.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) { }
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
    private var baseURL: String { "\(origin)/student" }
    private var loginURL: String { "\(baseURL)/login" }
    private var homeURL: String { "\(baseURL)/home" }

    /// Port of `AuthRepository.login`.
    ///
    /// The salt, login and cookie persistence all happen inside one continuous `URLSession`
    /// cookie context. Splitting them allows the server to see a request without the pre-session
    /// cookie and answer with a captcha challenge instead of accepting valid credentials.
    func login(username: String, password: String) async throws {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else { throw PortalError.loginRejected("请输入账号和密码") }

        // A dedicated client keeps the login handshake isolated from the cached session.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 40
        let client = URLSession(configuration: configuration)

        // Prime the pre-session cookie. Real EAMS deployments reject a correct password when the
        // login page has never been opened in the same session.
        var pageRequest = URLRequest(url: URL(string: loginURL)!)
        pageRequest.httpMethod = "GET"
        pageRequest.setValue(homeURL, forHTTPHeaderField: "Referer")
        pageRequest.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        pageRequest.setValue(Self.languageHeader, forHTTPHeaderField: "Accept-Language")
        _ = try await perform(client, pageRequest)

        var saltRequest = URLRequest(url: URL(string: "\(baseURL)/login-salt")!)
        applyAjaxHeaders(&saltRequest, referer: loginURL)
        let saltData = try await perform(client, saltRequest)
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
        let responseData = try await perform(client, loginRequest)

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

        guard let cookies = HTTPCookieStorage.shared.cookies(for: URL(string: loginURL)!),
              cookies.contains(where: { $0.name == "SESSION" && !$0.value.isEmpty }) else {
            throw PortalError.noSession
        }
        // The login endpoint accepted the request, so persist the session immediately. Home page
        // structure detection is content reading and must not invalidate a completed login.
        SessionStore.shared.saveCookieHeader(
            cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        )
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

    private func perform(_ client: URLSession, _ request: URLRequest) async throws -> Data {
        let (data, response) = try await client.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PortalError.invalidResponse }
        guard (200..<400).contains(http.statusCode) else { throw PortalError.requestFailed(http.statusCode) }
        return data
    }

    static func sha1Hex(_ value: String) -> String {
        Insecure.SHA1.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
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