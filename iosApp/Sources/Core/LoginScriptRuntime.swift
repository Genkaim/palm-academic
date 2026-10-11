import Foundation
import JavaScriptCore
import UIKit
import CommonCrypto
import CryptoKit
import Security

/// 学校登录脚本沙箱运行时（iOS 版，与安卓 `LoginScriptRuntime.kt` 同构，务必同步修改）。
///
/// 安全模型：
///  - 适配器 JS 运行在 JavaScriptCore 的 JSContext 中：没有 DOM、没有 window/document 网络
///    能力、没有任何文件或存储访问；重绘段因检测不到 PalmAcademicHost 而自行早退。
///  - 唯一对外通道是 `__PaNative` 桥；http 请求只能发往学校白名单主机的 https，同主机
///    http 仅允许自动升级为 https。
///  - 会话 cookie 由原生独立的内存 cookie 罐持有，永远不回传给 JS。
///  - 密码不进入 JS：JS 只持有占位符 `__PA_PASSWORD__`，在 http/crypto 边界由原生替换。
///
/// 所有 JSContext 访问都串行化在 `jsQueue` 上。桥方法在该队列上以【同步】方式执行
/// http/crypto/sleep（与安卓 WebView binder 线程上的阻塞模型一致），完成后在同一线程
/// 回调 JS Promise；Swift 侧通过 `result` 桥恢复 continuation。
final class LoginScriptRuntime: @unchecked Sendable {
    struct Field: Hashable {
        let id: String
        let type: String // text|password|tel|captcha|smsCode
        let label: String
        let placeholder: String
        let required: Bool
        let captchaImageUrl: String?
        let captchaRefreshParam: String?
    }

    struct Checkbox: Hashable {
        let id: String
        let label: String
        let defaultChecked: Bool
        let scope: String // local | request
    }

    struct Method: Hashable {
        let id: String
        let kind: String // password|sms|qrcode
        let label: String
        let isDefault: Bool
        let fields: [Field]
        let checkboxes: [Checkbox]
    }

    /// `methodSwitch` 必须由脚本在 describe() 顶层显式声明为 true，界面才渲染方式切换菜单。
    struct Schema {
        let methods: [Method]
        let methodSwitch: Bool
    }

    struct SubmitResult {
        let ok: Bool
        let kind: String
        let message: String
        let captchaUrl: String?
        let captchaRefreshParam: String?
        let challenge: Challenge?
        /// ok=true 时携带沙箱 cookie 罐中的完整会话 cookie，由 MainActor 控制器持久化
        /// （SessionStore 是 @MainActor，不能在 jsQueue 上触碰）。
        let sessionCookies: [HTTPCookie]
    }

    struct Challenge {
        let id: String
        let title: String
        let message: String
        let inputLabel: String
        let placeholder: String
        let sendCode: Bool
        let sendLabel: String
        let rememberLabel: String?
        let rememberDefault: Bool
    }

    enum UIEvent {
        case qr(state: String, message: String, image: UIImage?)
        case toast(String)
        case phase(String, String)
    }

    enum RuntimeError: LocalizedError {
        case generic(String)
        var errorDescription: String? {
            switch self { case .generic(let message): return message }
        }
    }

    static let passwordToken = "__PA_PASSWORD__"
    private static let keyboardChars = Array("ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678")
    private static let loginUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    private let adapterScript: String
    private let allowedHosts: Set<String>
    private let sessionCookieNames: [String]
    private let successUrlPrefixes: [String]
    private let loginUrl: String?
    private let onEvent: (UIEvent) -> Void
    private let redirectGuard: LoginScriptRedirectGuard

    private let jsQueue = DispatchQueue(label: "cn.edu.cupk.palmacademic.login-script")
    private var context: JSContext?
    private let bridge = ScriptNativeBridge()
    private var adapterCalls: [Int: CheckedContinuation<String, Error>] = [:]
    private var adapterSeq = 0
    private var closed = false
    private var password = ""
    private var lastFinalURLString = ""
    private var primedHosts = Set<String>()

    /// 单次登录专用的内存 cookie 罐：与全局 HTTPCookieStorage / WebKit 完全隔离，
    /// 仅在脚本回报登录成功并通过会话校验后才持久化。
    private let cookieStorage: HTTPCookieStorage
    private let session: URLSession

    init(
        adapterScript: String,
        allowedHosts: Set<String>,
        sessionCookieNames: [String],
        successUrlPrefixes: [String],
        loginUrl: String?,
        initialCookies: [HTTPCookie] = [],
        onEvent: @escaping (UIEvent) -> Void
    ) {
        self.adapterScript = adapterScript
        let normalizedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.allowedHosts = normalizedHosts
        self.sessionCookieNames = sessionCookieNames
        self.successUrlPrefixes = successUrlPrefixes
        self.loginUrl = loginUrl
        self.onEvent = onEvent
        let redirectGuard = LoginScriptRedirectGuard(allowedHosts: normalizedHosts)
        self.redirectGuard = redirectGuard

        let jar = HTTPCookieStorage()
        jar.cookieAcceptPolicy = .always
        initialCookies.forEach(jar.setCookie)
        cookieStorage = jar
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = jar
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(
            configuration: configuration,
            delegate: redirectGuard,
            delegateQueue: nil
        )
        bridge.attach(self)
    }

    // MARK: - Lifecycle

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            jsQueue.async {
                // JSContext() 在 Swift 中是可失败初始化器（返回 JSContext?）。
                guard let context = JSContext() else {
                    continuation.resume(throwing: RuntimeError.generic("无法初始化登录脚本环境"))
                    return
                }
                context.name = "PalmAcademicLoginSandbox"
                context.exceptionHandler = { [weak self] _, exception in
                    guard let self else { return }
                    let message = exception?.toString() ?? "登录脚本错误"
                    self.failPendingAdapterCalls(message: message)
                }
                context.setObject(self.bridge, forKeyedSubscript: "__PaNative" as NSString)
                do {
                    try self.evaluate(Self.shim, in: context)
                    try self.evaluate(self.adapterScript, in: context)
                    self.context = context
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() {
        jsQueue.async { [weak self] in
            guard let self else { return }
            self.closed = true
            self.failPendingAdapterCalls(message: "登录已取消")
            self.context = nil
        }
    }

    // MARK: - Schema

    func describe() async throws -> Schema {
        let raw = try await callAdapter("describe", payload: [:])
        guard
            let data = raw.data(using: .utf8),
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawMethods = json["methods"] as? [[String: Any]], !rawMethods.isEmpty
        else { throw RuntimeError.generic("登录脚本缺少 methods") }
        let methods: [Method] = rawMethods.map { rawMethod in
            let fields: [Field] = (rawMethod["fields"] as? [[String: Any]])?.map { rawField in
                let captcha = rawField["captcha"] as? [String: Any]
                return Field(
                    id: rawField.string("id") ?? "",
                    type: rawField.string("type") ?? "text",
                    label: rawField.string("label") ?? (rawField.string("id") ?? ""),
                    placeholder: rawField.string("placeholder") ?? "",
                    required: (rawField["required"] as? Bool) ?? true,
                    captchaImageUrl: captcha?["url"] as? String,
                    captchaRefreshParam: captcha?["refreshParam"] as? String
                )
            } ?? []
            let checkboxes: [Checkbox] = (rawMethod["checkboxes"] as? [[String: Any]])?.map { raw in
                Checkbox(
                    id: raw.string("id") ?? "",
                    label: raw.string("label") ?? (raw.string("id") ?? ""),
                    defaultChecked: (raw["defaultChecked"] as? Bool) ?? false,
                    scope: raw.string("scope") ?? "request"
                )
            } ?? []
            return Method(
                id: rawMethod.string("id") ?? "",
                kind: rawMethod.string("kind") ?? "password",
                label: rawMethod.string("label") ?? (rawMethod.string("id") ?? ""),
                isDefault: (rawMethod["default"] as? Bool) ?? false,
                fields: fields,
                checkboxes: checkboxes
            )
        }
        guard methods.contains(where: { !$0.id.isEmpty }) else {
            throw RuntimeError.generic("登录脚本未声明任何登录方式")
        }
        return Schema(
            methods: methods,
            methodSwitch: (json["methodSwitch"] as? Bool) ?? false
        )
    }

    func submit(
        methodId: String,
        values: [String: String],
        checkboxes: [String: Bool],
        secretPassword: String
    ) async throws -> SubmitResult {
        let raw = try await callAdapter(
            "submit",
            payload: ["methodId": methodId, "values": values, "checkboxes": checkboxes],
            secret: secretPassword
        )
        return try await parseSubmitResult(raw)
    }

    private func parseSubmitResult(_ raw: String) async throws -> SubmitResult {
        guard let data = raw.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw RuntimeError.generic("登录脚本返回值无效") }
        let ok = (json["ok"] as? Bool) ?? false
        let kind = json.string("kind") ?? (ok ? "success" : "rejected")
        let captcha = json["captcha"] as? [String: Any]
        let challengeObject = json["challenge"] as? [String: Any]
        let message = json.string("message") ?? ""
        let challenge = challengeObject.map { value in
            Challenge(
                id: value.string("id") ?? "mfa",
                title: value.string("title") ?? "安全验证",
                message: value.string("message") ?? message,
                inputLabel: value.string("inputLabel") ?? "验证码",
                placeholder: value.string("placeholder") ?? "请输入验证码",
                sendCode: (value["sendCode"] as? Bool) ?? false,
                sendLabel: value.string("sendLabel") ?? "获取验证码",
                rememberLabel: value.string("rememberLabel").flatMap { $0.isEmpty ? nil : $0 },
                rememberDefault: (value["rememberDefault"] as? Bool) ?? true
            )
        }
        let sessionCookies: [HTTPCookie] = ok ? (try await verifiedCookiesOnJSQueue()) : []
        let result = SubmitResult(
            ok: ok,
            kind: kind,
            message: message,
            captchaUrl: captcha?["url"] as? String,
            captchaRefreshParam: captcha?["refreshParam"] as? String,
            challenge: challenge,
            sessionCookies: sessionCookies
        )
        return result
    }

    /// 会话校验依赖 jsQueue 独占的 finalUrl/cookie 罐状态，必须在 jsQueue 上执行；
    /// 通过后把完整 cookie 交回 MainActor 控制器持久化。
    private func verifiedCookiesOnJSQueue() async throws -> [HTTPCookie] {
        try await withCheckedThrowingContinuation { continuation in
            jsQueue.async {
                do {
                    continuation.resume(returning: try self.verifiedSessionCookies())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func sendSms(
        methodId: String,
        values: [String: String],
        checkboxes: [String: Bool],
        secretPassword: String
    ) async throws -> [String: Any] {
        let raw = try await callAdapter(
            "sendSms",
            payload: ["methodId": methodId, "values": values, "checkboxes": checkboxes],
            secret: secretPassword
        )
        guard
            let data = raw.data(using: .utf8),
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw RuntimeError.generic("短信发送返回值无效") }
        return json
    }

    func sendChallenge(
        methodId: String,
        values: [String: String],
        checkboxes: [String: Bool],
        challengeId: String,
        secretPassword: String
    ) async throws -> [String: Any] {
        let raw = try await callAdapter(
            "sendChallenge",
            payload: [
                "methodId": methodId,
                "values": values,
                "checkboxes": checkboxes,
                "challengeId": challengeId
            ],
            secret: secretPassword
        )
        guard let data = raw.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw RuntimeError.generic("安全验证码发送返回值无效") }
        return json
    }

    func submitChallenge(
        methodId: String,
        values: [String: String],
        checkboxes: [String: Bool],
        challengeId: String,
        code: String,
        remember: Bool,
        secretPassword: String
    ) async throws -> SubmitResult {
        let raw = try await callAdapter(
            "submitChallenge",
            payload: [
                "methodId": methodId,
                "values": values,
                "checkboxes": checkboxes,
                "challengeId": challengeId,
                "code": code,
                "remember": remember
            ],
            secret: secretPassword
        )
        return try await parseSubmitResult(raw)
    }

    /// 拉取图形验证码。首次取图前先 GET 一次登录页建立服务端预会话（金智验证码依赖会话
    /// cookie），与后续 submit 共用同一个 cookie 罐；响应若为安全防护拦截页则重建预会话重试。
    func fetchCaptcha(_ rawURLString: String, refreshParam: String?) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            jsQueue.async {
                do {
                    let baseURL = try self.authorizedURL(rawURLString)
                    func captchaRequest() throws -> URLRequest {
                        var url = baseURL
                        if let refreshParam, !refreshParam.isEmpty,
                           var components = URLComponents(
                               url: url, resolvingAgainstBaseURL: false
                           ) {
                            var items = components.queryItems ?? []
                            items.removeAll { $0.name == refreshParam }
                            items.append(URLQueryItem(
                                name: refreshParam,
                                value: String(Int64(Date().timeIntervalSince1970 * 1000))
                            ))
                            components.queryItems = items
                            if let rebuilt = components.url { url = rebuilt }
                        }
                        var request = URLRequest(url: url)
                        request.setValue(Self.loginUserAgent, forHTTPHeaderField: "User-Agent")
                        request.setValue(
                            "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
                            forHTTPHeaderField: "Accept"
                        )
                        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
                        request.setValue(self.loginUrl ?? url.absoluteString, forHTTPHeaderField: "Referer")
                        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                        return request
                    }

                    try self.ensurePrimed()
                    for round in 0..<2 {
                        let (data, response) = try self.blockingLoad(try captchaRequest())
                        guard (200..<300).contains(response.statusCode) else {
                            throw RuntimeError.generic("验证码加载失败（\(response.statusCode)）")
                        }
                        if Self.isImageBytes(data) {
                            continuation.resume(returning: data)
                            return
                        }
                        // 拦截页/空响应：重新建立预会话后只再试一轮。
                        if round == 0,
                           let host = self.loginUrl.flatMap({ URL(string: $0)?.host }) {
                            self.primedHosts.remove(host)
                            try? self.ensurePrimed()
                        }
                    }
                    throw RuntimeError.generic("验证码响应被安全防护拦截，请点击刷新重试")
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 嗅探常见图片格式魔数，避免把拦截页 HTML 当作验证码渲染。
    private static func isImageBytes(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let b = [UInt8](data.prefix(12))
        // JPEG FF D8 FF | PNG 89 50 4E 47 | GIF 47 49 46 | BMP 42 4D | WEBP RIFF....WEBP
        if b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return true }
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return true }
        if b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 { return true }
        if b[0] == 0x42 && b[1] == 0x4D { return true }
        if b[0] == 0x52 && b[1] == 0x49 && b[8] == 0x57 &&
            b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50 { return true }
        return false
    }

    // MARK: - Adapter invocation

    private func callAdapter(
        _ name: String,
        payload: [String: Any],
        secret: String? = nil
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            jsQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: RuntimeError.generic("登录运行时已释放"))
                    return
                }
                // 密码只在 jsQueue 上写入，与占位符替换/桥调用同线程，避免数据竞争。
                if let secret { self.password = secret }
                self.adapterSeq += 1
                let id = self.adapterSeq
                self.adapterCalls[id] = continuation
                let payloadJSON = self.jsonString(payload)
                let script = "__paCallAdapter(\(id),\(self.jsonString(name)),\(payloadJSON))"
                guard let context = self.context else {
                    self.adapterCalls.removeValue(forKey: id)
                    continuation.resume(throwing: RuntimeError.generic("登录运行时未初始化"))
                    return
                }
                context.evaluateScript(script)
            }
        }
    }

    fileprivate func deliverAdapterResult(reqId: Int, ok: Bool, json: String) {
        // The adapter Promise has settled, so no later host call from this invocation may need
        // the secret. Clear it before resuming native code.
        password = ""
        guard let continuation = adapterCalls.removeValue(forKey: reqId) else { return }
        if ok {
            continuation.resume(returning: json)
        } else {
            var message = "登录脚本错误"
            if let data = json.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = payload.string("message"), !text.isEmpty {
                message = text
            }
            continuation.resume(throwing: RuntimeError.generic(message))
        }
    }

    private func failPendingAdapterCalls(message: String) {
        password = ""
        let pending = Array(adapterCalls.values)
        adapterCalls.removeAll()
        pending.forEach { $0.resume(throwing: RuntimeError.generic(message)) }
    }

    // MARK: - Host bridge (runs synchronously on jsQueue)

    fileprivate func handleHostCall(callId: Int, method: String, argsJSON: String) {
        if closed {
            resolveHostCall(callId, ok: false, message: "登录已取消")
            return
        }
        do {
            let args = try parseJSONObject(argsJSON)
            switch method {
            case "http":
                let response = try performHTTP(args)
                resolveHostCall(callId, json: response)
            case "crypto":
                let value = try performCrypto(args)
                resolveHostCall(callId, json: ["value": value])
            case "sleep":
                let milliseconds = (args["ms"] as? NSNumber)?.intValue ?? 0
                Thread.sleep(forTimeInterval: Double(max(0, min(120_000, milliseconds))) / 1000.0)
                resolveHostCall(callId, json: [:])
            case "ui":
                handleUI(args)
                resolveHostCall(callId, json: [:])
            default:
                resolveHostCall(callId, ok: false, message: "未知能力 \(method)")
            }
        } catch let error as RuntimeError {
            resolveHostCall(callId, ok: false, message: error.errorDescription ?? "登录运行时错误")
        } catch {
            resolveHostCall(callId, ok: false, message: error.localizedDescription)
        }
    }

    private func resolveHostCall(_ callId: Int, json: [String: Any]) {
        guard let context else { return }
        let script = "__paHostResolve(\(callId),true,\(jsonString(json)))"
        context.evaluateScript(script)
    }

    private func resolveHostCall(_ callId: Int, ok: Bool, message: String) {
        guard let context else { return }
        let script = "__paHostResolve(\(callId),false,\(jsonString(["message": message])))"
        context.evaluateScript(script)
    }

    // MARK: - HTTP（限域、占位符替换）

    private func performHTTP(_ args: [String: Any]) throws -> [String: Any] {
        let rawURLString = substitute(args.string("url") ?? "")
        guard !rawURLString.isEmpty else { throw RuntimeError.generic("http.url 为空") }
        let url = try authorizedURL(rawURLString)

        var request = URLRequest(url: url)
        request.setValue(Self.loginUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpMethod = (args.string("method") ?? "GET").uppercased()
        if let headers = args["headers"] as? [String: Any] {
            for (key, value) in headers {
                request.setValue(substitute(String(describing: value)), forHTTPHeaderField: key)
            }
        }
        if let form = args["form"] as? [String: Any] {
            let pairs: [(String, String)] = form.map { key, value in
                (key, String(describing: value))
            }
            let body = pairs
                .map { "\(formEncode($0.0))=\(formEncode(substitute($0.1)))" }
                .sorted()
                .joined(separator: "&")
            request.setValue(
                "application/x-www-form-urlencoded; charset=utf-8",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = Data(body.utf8)
        } else if let json = args["json"] {
            let substituted = deepSubstitute(json)
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(
                withJSONObject: substituted,
                options: [.fragmentsAllowed]
            )
        } else if let body = args.string("body") {
            request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(substitute(body).utf8)
        }

        let (data, response) = try blockingLoad(request)
        let text = String(decoding: data, as: UTF8.self)
        lastFinalURLString = response.url?.absoluteString ?? url.absoluteString
        return [
            "status": response.statusCode,
            "finalUrl": lastFinalURLString,
            "text": text
        ]
    }

    private func authorizedURL(_ rawURLString: String) throws -> URL {
        guard
            var components = URLComponents(string: rawURLString),
            let host = components.host,
            !host.isEmpty
        else { throw RuntimeError.generic("登录请求地址无效：\(rawURLString)") }
        if components.scheme?.lowercased() == "http" && allowedHosts.contains(host) {
            // 仅允许同主机明文自动升级 https（与安卓/WebView 行为一致）。
            components.scheme = "https"
        }
        guard components.scheme?.lowercased() == "https" else {
            throw RuntimeError.generic("登录请求仅允许 https：\(rawURLString)")
        }
        guard allowedHosts.contains(host) else {
            throw RuntimeError.generic("登录脚本试图访问未授权主机：\(host)")
        }
        guard let url = components.url else {
            throw RuntimeError.generic("登录请求地址无效：\(rawURLString)")
        }
        return url
    }

    private func blockingLoad(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: HTTPURLResponse?
        var resultError: Error?
        let task = session.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response as? HTTPURLResponse
            resultError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        if let resultError { throw resultError }
        guard let response = resultResponse else {
            throw RuntimeError.generic("登录请求没有响应")
        }
        return (resultData ?? Data(), response)
    }

    private func ensurePrimed() throws {
        guard let loginUrl, let url = URL(string: loginUrl) else { return }
        guard let host = url.host, allowedHosts.contains(host), primedHosts.insert(host).inserted
        else { return }
        var request = URLRequest(url: url)
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        _ = try? blockingLoad(request)
    }

    private func verifiedSessionCookies() throws -> [HTTPCookie] {
        let urlOK = successUrlPrefixes.isEmpty ||
            successUrlPrefixes.contains { lastFinalURLString.hasPrefix($0) }
        let cookieOK = hasAnyCookie(sessionCookieNames)
        guard urlOK && cookieOK else {
            throw RuntimeError.generic("登录脚本回报成功，但未建立有效会话")
        }
        return cookieStorage.cookies ?? []
    }

    private func hasAnyCookie(_ names: [String]) -> Bool {
        let cookies = cookieStorage.cookies ?? []
        return cookies.contains { cookie in
            !cookie.value.isEmpty && (names.isEmpty || names.contains {
                $0.caseInsensitiveCompare(cookie.name) == .orderedSame
            })
        }
    }

    // MARK: - 占位符替换

    private func substitute(_ value: String) -> String {
        guard !password.isEmpty, value.contains(Self.passwordToken) else { return value }
        return value.replacingOccurrences(of: Self.passwordToken, with: password)
    }

    private func deepSubstitute(_ value: Any) -> Any {
        switch value {
        case let string as String:
            return substitute(string)
        case let object as [String: Any]:
            return object.mapValues(deepSubstitute)
        case let array as [Any]:
            return array.map(deepSubstitute)
        default:
            return value
        }
    }

    // MARK: - crypto（密码仅在边界替换；明文不回传 JS）

    private func performCrypto(_ args: [String: Any]) throws -> String {
        switch args.string("op") {
        case "sha1":
            return Self.sha1Hex(substitute(args.string("data") ?? ""))
        case "md5":
            return Self.md5Hex(substitute(args.string("data") ?? ""))
        case "rsa-pkcs1":
            return try Self.rsaEncryptBase64(
                substitute(args.string("data") ?? ""),
                publicKeyBase64: substitute(args.string("publicKey") ?? "")
            )
        case "aes-cbc-pkcs7":
            guard let keyString = args.string("key") else {
                throw RuntimeError.generic("aes-cbc-pkcs7 缺少 key")
            }
            let key = Data(substitute(keyString).utf8)
            let iv = Data(substitute(args.string("iv") ?? "").utf8)
            let prefixLength = (args["prefixLength"] as? NSNumber)?.intValue ?? 0
            return try aesCBC(
                plain: substitute(args.string("data") ?? ""),
                key: key,
                iv: iv,
                prefixLength: prefixLength
            )
        default:
            throw RuntimeError.generic("不支持的加密算法：\(args.string("op") ?? "")")
        }
    }

    /// AES/CBC/PKCS7，对齐安卓 `AES/CBC/PKCS5Padding` + Base64 NO_WRAP。
    /// 未提供 16 字节 IV 时原生自生随机 IV（密文不携带 IV，首块由随机前缀吸收）。
    private func aesCBC(plain: String, key: Data, iv providedIV: Data, prefixLength: Int) throws -> String {
        guard key.count == 16 || key.count == 24 || key.count == 32 else {
            throw RuntimeError.generic("AES key 长度必须为 16/24/32")
        }
        let iv: Data
        if providedIV.count == kCCBlockSizeAES128 {
            iv = providedIV
        } else {
            iv = Data(randomPrefix(16).utf8)
        }
        var data = Data()
        if prefixLength > 0 {
            data.append(Data(randomPrefix(prefixLength).utf8))
        }
        data.append(Data(plain.utf8))

        var output = Data(count: data.count + kCCBlockSizeAES128)
        // output 在 withUnsafeMutableBytes 期间被独占借用，长度必须先拷贝，
        // 否则触发 Swift 独占访问冲突（overlapping accesses）。
        let outputLength = output.count
        var movedLength = 0
        let status = output.withUnsafeMutableBytes { outputRaw in
            data.withUnsafeBytes { dataRaw in
                iv.withUnsafeBytes { ivRaw in
                    key.withUnsafeBytes { keyRaw in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyRaw.baseAddress, key.count,
                            ivRaw.baseAddress,
                            dataRaw.baseAddress, data.count,
                            outputRaw.baseAddress, outputLength,
                            &movedLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw RuntimeError.generic("AES 加密失败（\(status)）")
        }
        return output.prefix(movedLength).base64EncodedString()
    }

    private func randomPrefix(_ length: Int) -> String {
        guard length > 0 else { return "" }
        var result = ""
        let characters = Self.keyboardChars
        for _ in 0..<length {
            // SecRandomCopyBytes 对应安卓 SecureRandom：键盘字符集排除了易混字符。
            var byte: UInt8 = 0
            SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
            result.append(characters[Int(byte) % characters.count])
        }
        return result
    }

    // MARK: - 非隔离加密原语（与 AuthRepository 中的 @MainActor 版本等价，但
    // 沙箱桥调用发生在 jsQueue，不能跨越 actor，因此这里自带实现。）

    fileprivate static func sha1Hex(_ value: String) -> String {
        Insecure.SHA1.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// MD5 仅服务于遗留学校协议（CryptoKit 未提供），与安卓 MessageDigest("MD5") 对齐。
    fileprivate static func md5Hex(_ value: String) -> String {
        let input = Array(value.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        input.withUnsafeBufferPointer { pointer in
            _ = CC_MD5(pointer.baseAddress, CC_LONG(input.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// RSA/PKCS1 + X.509 SubjectPublicKeyInfo(base64) 公钥，对应安卓
    /// `Cipher.getInstance("RSA/ECB/PKCS1Padding")`。
    fileprivate static func rsaEncryptBase64(
        _ plain: String,
        publicKeyBase64: String
    ) throws -> String {
        guard let keyData = Data(base64Encoded: publicKeyBase64) else {
            throw RuntimeError.generic("RSA 公钥不是有效的 Base64")
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) else {
            throw RuntimeError.generic("RSA 公钥无法解析")
        }
        guard SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionPKCS1),
              let encrypted = SecKeyCreateEncryptedData(
                key, .rsaEncryptionPKCS1, Data(plain.utf8) as CFData, &error
              ) else {
            throw RuntimeError.generic("密码加密失败")
        }
        return (encrypted as Data).base64EncodedString()
    }

    // MARK: - UI 事件（二维码等）

    private func handleUI(_ args: [String: Any]) {
        switch args.string("type") {
        case "qr":
            let state = args.string("state") ?? "waiting"
            let message = args.string("message") ?? ""
            var image: UIImage?
            if let base64 = args.string("imageBase64"),
               let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
                image = UIImage(data: data)
            } else if let imageURLString = args.string("imageUrl") {
                image = fetchBitmap(imageURLString)
            }
            let event = UIEvent.qr(state: state, message: message, image: image)
            DispatchQueue.main.async { [onEvent] in onEvent(event) }
        case "toast":
            let message = args.string("message") ?? ""
            DispatchQueue.main.async { [onEvent] in onEvent(.toast(message)) }
        case "state":
            let state = args.string("state") ?? ""
            let message = args.string("message") ?? ""
            DispatchQueue.main.async { [onEvent] in onEvent(.phase(state, message)) }
        default:
            break
        }
    }

    private func fetchBitmap(_ rawURLString: String) -> UIImage? {
        guard let url = try? authorizedURL(substitute(rawURLString)) else {
            return nil
        }
        guard let (data, response) = try? blockingLoad(URLRequest(url: url)),
              (200..<300).contains(response.statusCode),
              !data.isEmpty else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Helpers

    private func parseJSONObject(_ text: String) throws -> [String: Any] {
        guard
            let data = text.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private func evaluate(_ script: String, in context: JSContext) throws {
        context.evaluateScript(script)
        if let exception = context.exception {
            throw RuntimeError.generic(exception.toString() ?? "登录脚本错误")
        }
    }

    private func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let string = String(data: data, encoding: .utf8) else {
            if let string = value as? String {
                return (try? JSONSerialization.data(
                    withJSONObject: string,
                    options: [.fragmentsAllowed]
                )).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            }
            return "null"
        }
        return string
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: " &=+?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

@objc private protocol ScriptNativeBridgeProtocol: JSExport {
    func hostCall(_ callId: Int, _ method: String, _ argsJson: String)
    func result(_ reqId: Int, _ ok: Bool, _ json: String)
}

/// JSExport 需要一个 NSObject 桥。方法全部在 JSContext 所属的 jsQueue 上被调用。
private final class ScriptNativeBridge: NSObject, ScriptNativeBridgeProtocol {
    private weak var runtime: LoginScriptRuntime?

    func attach(_ runtime: LoginScriptRuntime) {
        self.runtime = runtime
    }

    func hostCall(_ callId: Int, _ method: String, _ argsJson: String) {
        runtime?.handleHostCall(callId: callId, method: method, argsJSON: argsJson)
    }

    func result(_ reqId: Int, _ ok: Bool, _ json: String) {
        runtime?.deliverAdapterResult(reqId: reqId, ok: ok, json: json)
    }
}

/// URLSession follows redirects before returning a response to the runtime. Enforce the same
/// HTTPS school-host allowlist on every hop so 307/308 cannot forward credentials off-site.
private final class LoginScriptRedirectGuard: NSObject, URLSessionTaskDelegate {
    private let allowedHosts: Set<String>

    init(allowedHosts: Set<String>) {
        self.allowedHosts = allowedHosts
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedHosts.contains(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        self[key] as? String
    }
}

/// 与安卓 LoginScriptRuntime.SHIM 逐行等价：唯一差别是 JSContext 没有 window，
/// 这里先把 window 指向全局对象，重绘段 `if (!window.PalmAcademicHost) return` 才会早退。
private let loginRuntimeShim: String = """
window = this;
(function(){
  if (window.__paReady) return; window.__paReady = true;
  var seq = 1, pending = {};
  window.__paHostResolve = function(id, ok, payloadJson){
    var p = pending[id]; if (!p) return; delete pending[id];
    var payload = null;
    try { payload = payloadJson ? JSON.parse(payloadJson) : null; } catch (e) { payload = payloadJson; }
    if (ok) { p.resolve(payload); }
    else { p.reject(new Error((payload && payload.message) || 'login host error')); }
  };
  function hostCall(method, args){
    return new Promise(function(resolve, reject){
      var id = seq++; pending[id] = { resolve: resolve, reject: reject };
      window.__PaNative.hostCall(id, method, JSON.stringify(args || {}));
    });
  }
  window.PalmAcademic = {
    http: function(req){ return hostCall('http', req); },
    crypto: function(spec){ return hostCall('crypto', spec).then(function(r){ return r.value; }); },
    sleep: function(ms){ return hostCall('sleep', { ms: ms }); },
    ui: function(evt){ return hostCall('ui', evt); }
  };
  window.__paCallAdapter = function(reqId, name, payloadJson){
    Promise.resolve().then(function(){
      var A = window.PalmAcademicLoginAdapter;
      if (!A) throw new Error('缺少 PalmAcademicLoginAdapter');
      var fn = A[name];
      if (typeof fn !== 'function') throw new Error('登录脚本缺少方法 ' + name);
      var arg = payloadJson ? JSON.parse(payloadJson) : null;
      return fn.call(A, arg);
    }).then(function(value){
      window.__PaNative.result(reqId, true, JSON.stringify(value === undefined ? null : value));
    }, function(err){
      window.__PaNative.result(reqId, false, JSON.stringify({ message: String((err && err.message) || err) }));
    });
  };
})();
"""

extension LoginScriptRuntime {
    fileprivate static var shim: String { loginRuntimeShim }
}

enum ScriptSilentLoginState: Sendable { case success, interactionRequired, rejected, retry }

struct ScriptSilentLoginResult: Sendable {
    let state: ScriptSilentLoginState
    let message: String
}

/// Replays the script adapter's password method without presenting UI. MFA/captcha are returned as
/// interactionRequired; only transport/runtime errors are retryable.
@MainActor
enum ScriptSilentLogin {
    static func attempt(
        definition: SchoolDefinition,
        credential: (username: String, password: String)
    ) async -> ScriptSilentLoginResult {
        guard let auth = definition.auth else {
            return ScriptSilentLoginResult(state: .retry, message: "学校定义缺少 auth")
        }
        let scriptPath = auth.loginScript ?? definition.readerAdapter
        let script = SchoolCatalog.shared.readAdapterScript(assetPath: scriptPath)
        let volatileNames = Set((auth.resolvedCookieNames + ["JSESSIONID", "CASTGC"]).map {
            $0.uppercased()
        })
        let initialCookies = SessionStore.shared.cookiesForScriptLogin.filter { cookie in
            !volatileNames.contains(cookie.name.uppercased()) &&
                !cookie.name.uppercased().contains("TICKET")
        }
        let runtime = LoginScriptRuntime(
            adapterScript: script,
            allowedHosts: auth.allowedHosts(baseURL: definition.baseUrl),
            sessionCookieNames: auth.resolvedCookieNames,
            successUrlPrefixes: auth.resolvedSuccessPrefixes,
            loginUrl: auth.loginUrl,
            initialCookies: initialCookies,
            onEvent: { _ in }
        )
        defer { runtime.close() }
        do {
            try await runtime.start()
            let schema = try await runtime.describe()
            guard let method = schema.methods.first(where: { $0.kind == "password" && $0.isDefault })
                    ?? schema.methods.first(where: { $0.kind == "password" }) else {
                return ScriptSilentLoginResult(
                    state: .interactionRequired,
                    message: "当前学校未提供可自动重登的密码方式"
                )
            }
            let usernameField = method.fields.first(where: { $0.id == "username" })
                ?? method.fields.first(where: { $0.type == "text" || $0.type == "tel" })
            guard let usernameField,
                  let passwordField = method.fields.first(where: { $0.type == "password" }),
                  !method.fields.contains(where: {
                      $0.required && $0.id != usernameField.id && $0.id != passwordField.id
                  }) else {
                return ScriptSilentLoginResult(
                    state: .interactionRequired,
                    message: "自动登录需要补充安全验证"
                )
            }
            var values = Dictionary(uniqueKeysWithValues: method.fields.map { ($0.id, "") })
            values[usernameField.id] = credential.username
            values[passwordField.id] = LoginScriptRuntime.passwordToken
            let checks = Dictionary(uniqueKeysWithValues: method.checkboxes.map {
                ($0.id, $0.defaultChecked)
            })
            let result = try await runtime.submit(
                methodId: method.id,
                values: values,
                checkboxes: checks,
                secretPassword: credential.password
            )
            if result.ok {
                SessionStore.shared.saveCookies(result.sessionCookies)
                SessionStore.shared.restoreToCookieStorage()
                return ScriptSilentLoginResult(state: .success, message: "")
            }
            if result.kind == "mfa" || result.kind == "captcha" {
                return ScriptSilentLoginResult(
                    state: .interactionRequired,
                    message: result.message.isEmpty ? "登录需要完成安全验证" : result.message
                )
            }
            return ScriptSilentLoginResult(
                state: .rejected,
                message: result.message.isEmpty ? "保存的密码已失效" : result.message
            )
        } catch {
            return ScriptSilentLoginResult(state: .retry, message: error.localizedDescription)
        }
    }
}
