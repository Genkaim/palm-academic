import UIKit
import SwiftUI

/// type=script 学校的登录控制器（iOS 版，与安卓 `ScriptLoginController` 一一对应）。
///
/// 持有离屏 JavaScriptCore 沙箱运行时与 schema 驱动的登录状态，负责账号密码 / 短信 / 扫码
/// 三类登录。本类不包含任何界面：脚本学校复用既有 LoginView，只在该页上增量挂载方式切换、
/// 短信验证码、二维码面板、验证码挑战/失败弹窗，不另起登录页面。
///
/// 密码仅在提交边界离开 UI 状态进入原生（占位符 `__PA_PASSWORD__` 进入 JS）。
@MainActor
final class ScriptLoginController: ObservableObject {
    enum Phase { case loading, ready }

    struct CaptchaChallenge: Identifiable {
        let id = UUID()
        let imageUrl: String
        let refreshParam: String?
        /// 确认后验证码写入的字段键（固定字段 id 或动态 "captcha"）。
        let targetKey: String
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var initError: String?
    @Published private(set) var methods: [LoginScriptRuntime.Method] = []
    /// 脚本显式声明 methodSwitch:true 时才允许显示方式切换菜单。
    @Published private(set) var methodSwitch = false
    @Published private(set) var methodId = ""
    @Published private(set) var busy = false
    @Published var status: String?
    @Published var error: String?
    @Published private(set) var qrImage: UIImage?
    @Published private(set) var qrState = ""
    @Published private(set) var qrMessage = ""

    /// 密码登录被要求输入验证码时弹出的挑战框（nil=不显示）。
    @Published var captchaChallenge: CaptchaChallenge?
    @Published var captchaDialogInput = ""
    @Published private(set) var captchaDialogImage: Data?
    /// 短信/扫码等方式登录失败时的模态弹窗消息（nil=不显示）。
    @Published var failureDialog: String?
    @Published private(set) var mfaChallenge: LoginScriptRuntime.Challenge?
    @Published var mfaCode = ""
    @Published var mfaRemember = true
    @Published private(set) var mfaBusy = false
    @Published private(set) var mfaError: String?
    @Published private(set) var mfaCooldown = 0

    @Published var values: [String: String] = [:]
    @Published var checkboxes: [String: Bool] = [:]
    @Published var captchaImages: [String: Data] = [:]
    @Published private(set) var smsCooldown = 0

    private var runtime: LoginScriptRuntime?
    private var submitTask: Task<Void, Never>?
    private var cooldownTask: Task<Void, Never>?
    private var mfaCooldownTask: Task<Void, Never>?
    private var automaticPasswordSubmitRequested = false

    private let onAuthenticated: () -> Void
    private let onRemember: (_ username: String, _ password: String) -> Void
    private let onForget: () -> Void
    /// 钥匙串中已保存凭证的回填值（如 username/password），仅在 schema 含同名字段时生效。
    private let prefillValues: [String: String]

    init(
        prefillValues: [String: String] = [:],
        onAuthenticated: @escaping () -> Void,
        onRemember: @escaping (String, String) -> Void,
        onForget: @escaping () -> Void
    ) {
        self.prefillValues = prefillValues
        self.onAuthenticated = onAuthenticated
        self.onRemember = onRemember
        self.onForget = onForget
    }

    // MARK: - Lifecycle

    func start(definition: SchoolDefinition) {
        phase = .loading
        initError = nil
        guard let auth = definition.auth else {
            initError = "学校定义缺少 auth"
            phase = .ready
            return
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
            sessionCookieNames: auth.sessionCookieNames ?? ["SESSION"],
            successUrlPrefixes: auth.resolvedSuccessPrefixes,
            loginUrl: auth.loginUrl,
            initialCookies: initialCookies,
            onEvent: { [weak self] event in
                Task { @MainActor in self?.applyUIEvent(event) }
            }
        )
        self.runtime = runtime
        Task {
            do {
                try await runtime.start()
                let schema = try await runtime.describe()
                methods = schema.methods
                methodSwitch = schema.methodSwitch
                let defaultMethod = schema.methods.first(where: \.isDefault) ?? schema.methods[0]
                bindMethod(defaultMethod)
                phase = .ready
                if automaticPasswordSubmitRequested && defaultMethod.kind == "password" {
                    automaticPasswordSubmitRequested = false
                    submit()
                } else if defaultMethod.kind == "qrcode" {
                    launchQr(defaultMethod)
                }
            } catch {
                initError = error.localizedDescription
                phase = .ready
            }
        }
    }

    func close() {
        submitTask?.cancel()
        cooldownTask?.cancel()
        mfaCooldownTask?.cancel()
        runtime?.close()
        runtime = nil
    }

    /// Replays saved credentials once so an expired background session opens the native MFA
    /// challenge directly instead of making the user press the password-login button again.
    func requestAutomaticPasswordSubmit() {
        automaticPasswordSubmitRequested = true
        if phase == .ready, currentMethod()?.kind == "password" {
            automaticPasswordSubmitRequested = false
            submit()
        }
    }

    // MARK: - Methods

    func currentMethod() -> LoginScriptRuntime.Method? {
        methods.first { $0.id == methodId }
    }

    func selectMethod(_ method: LoginScriptRuntime.Method) {
        guard methodSwitch, method.id != methodId else { return }
        submitTask?.cancel()
        busy = false
        error = nil
        status = nil
        bindMethod(method)
        if method.kind == "qrcode" { launchQr(method) }
    }

    private func bindMethod(_ method: LoginScriptRuntime.Method) {
        methodId = method.id
        // 切方法时清掉非通用字段（保留账号便于跨方式复用）。
        let keepUsername = values["username"] ?? ""
        values.removeAll()
        if !keepUsername.isEmpty { values["username"] = keepUsername }
        for field in method.fields where field.type == "captcha" {
            values[field.id] = ""
        }
        // 回填已保存凭证：仅写入当前方式确实存在的字段（短信/扫码方式没有 password 字段，
        // 密码不会跨方式泄漏到提交值里）。验证码等已被置空的字段不覆盖。
        for (key, saved) in prefillValues where !saved.isEmpty {
            if method.fields.contains(where: { $0.id == key }), values[key] == nil {
                values[key] = saved
            }
        }
        checkboxes.removeAll()
        for checkbox in method.checkboxes {
            checkboxes[checkbox.id] = checkbox.defaultChecked
        }
        qrImage = nil
        qrState = ""
        qrMessage = ""
        captchaChallenge = nil
        captchaDialogInput = ""
        captchaDialogImage = nil
        mfaChallenge = nil
        mfaCode = ""
        mfaError = nil
        mfaBusy = false
        for field in method.fields where field.type == "captcha" {
            refreshCaptcha(field)
        }
    }

    func setValue(_ id: String, _ value: String) {
        values[id] = value
    }

    func toggleCheckbox(_ id: String) {
        checkboxes[id] = !(checkboxes[id] ?? false)
    }

    var canSubmitCurrent: Bool {
        guard let method = currentMethod(), !busy else { return false }
        return !method.fields.contains { field in
            field.required && (values[field.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // MARK: - Captcha images

    func refreshCaptcha(_ field: LoginScriptRuntime.Field) {
        guard let url = field.captchaImageUrl, let runtime else { return }
        Task {
            do {
                captchaImages[field.id] = try await runtime.fetchCaptcha(
                    url, refreshParam: field.captchaRefreshParam
                )
                error = nil
            } catch {
                captchaImages[field.id] = nil
                // 给出可见原因，用户可点击尾部图片区域直接重试。
                self.error = "图形验证码加载失败，请点击验证码图片重试"
            }
        }
    }

    // MARK: - SMS

    func sendSms(_ codeField: LoginScriptRuntime.Field) {
        guard let method = currentMethod(), smsCooldown == 0, !busy else { return }
        Task {
            busy = true
            error = nil
            status = "正在发送短信验证码…"
            do {
                let json = try await runtime?.sendSms(
                    methodId: method.id,
                    values: publicValues(),
                    checkboxes: checkboxes,
                    secretPassword: secretPassword()
                ) ?? [:]
                busy = false
                status = nil
                if (json["ok"] as? Bool) ?? false {
                    let seconds = max(1, (json["cooldownSeconds"] as? NSNumber)?.intValue ?? 60)
                    startCooldown(seconds)
                    if let message = json["message"] as? String, !message.isEmpty {
                        status = message
                    }
                } else {
                    error = (json["message"] as? String) ?? "短信发送失败"
                    if let captchaField = method.fields.first(where: { $0.type == "captcha" }) {
                        refreshCaptcha(captchaField)
                    }
                }
            } catch {
                busy = false
                status = nil
                self.error = error.localizedDescription
            }
        }
    }

    private func startCooldown(_ seconds: Int) {
        cooldownTask?.cancel()
        smsCooldown = seconds
        cooldownTask = Task {
            var remaining = seconds
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                remaining -= 1
                smsCooldown = remaining
            }
        }
    }

    // MARK: - Submit

    func submit() {
        guard let method = currentMethod(), !busy else { return }
        if let missing = method.fields.first(where: { field in
            field.required && (values[field.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }) {
            error = "请输入\(missing.label)"
            return
        }
        submitTask?.cancel()
        submitTask = Task {
            var attempt = 0
            // 密码方式的网络异常无限静默重试；短信/扫码是短交互，最多 3 轮后弹“登录失败”。
            let maxAttempts = method.kind == "password" ? Int.max : 3
            while !Task.isCancelled, attempt < maxAttempts {
                busy = true
                error = nil
                status = attempt == 0
                    ? "正在登录…"
                    : (method.kind == "password"
                        ? "登录未成功，正在重试（第 \(attempt) 次）…"
                        : "网络不稳定，正在重试（第 \(attempt) 次）…")
                do {
                    let result = try await runtime?.submit(
                        methodId: method.id,
                        values: publicValues(),
                        checkboxes: checkboxes,
                        secretPassword: secretPassword()
                    )
                    busy = false
                    status = nil
                    guard let result else { return }
                    if result.ok {
                        await persistAndFinish(sessionCookies: result.sessionCookies)
                        return
                    }
                    handleDefinitiveFailure(method, result)
                    return
                } catch {
                    busy = false
                    status = nil
                    attempt += 1
                    if attempt >= maxAttempts {
                        failureDialog = "网络异常，登录失败，请重新登录"
                        return
                    }
                    let backoff = min(1 << min(attempt - 1, 4), 16)
                    try? await Task.sleep(nanoseconds: UInt64(backoff) * 1_000_000_000)
                }
            }
        }
    }

    /// 统一登录失败策略（与安卓一致）：
    ///  - 非密码方式（短信/扫码）：弹“登录失败”模态框；
    ///  - 密码方式、脚本要求验证码或该方式含常驻图形验证码：弹验证码挑战框；
    ///  - 密码方式、无验证码：不弹窗，直接重新走 submit 持续重试。
    private func handleDefinitiveFailure(
        _ method: LoginScriptRuntime.Method,
        _ result: LoginScriptRuntime.SubmitResult
    ) {
        if result.kind == "mfa", let challenge = result.challenge {
            mfaChallenge = challenge
            mfaCode = ""
            mfaRemember = challenge.rememberDefault
            mfaError = nil
            return
        }
        if method.kind != "password" {
            failureDialog = result.message.isEmpty ? "登录失败，请检查后重试" : result.message
            return
        }
        // 优先使用脚本在需要验证码时动态给出的验证码图片地址。
        if result.kind == "captcha", let url = result.captchaUrl, !url.isEmpty {
            openCaptchaChallenge(url, refreshParam: result.captchaRefreshParam, targetKey: "captcha")
            return
        }
        // 其次使用该方式声明的常驻图形验证码字段。
        if let field = method.fields.first(where: { $0.type == "captcha" }),
           let url = field.captchaImageUrl, !url.isEmpty {
            openCaptchaChallenge(url, refreshParam: field.captchaRefreshParam, targetKey: field.id)
        } else {
            // 明确拒绝是终态；只有真正抛出的网络异常才由 submit() 自动重试。
            error = result.message.isEmpty ? "账号或密码错误" : result.message
        }
    }

    private func openCaptchaChallenge(
        _ imageUrl: String,
        refreshParam: String?,
        targetKey: String
    ) {
        captchaDialogInput = values[targetKey] ?? ""
        captchaDialogImage = nil
        captchaChallenge = CaptchaChallenge(
            imageUrl: imageUrl, refreshParam: refreshParam, targetKey: targetKey
        )
        refreshDialogCaptcha()
    }

    func refreshDialogCaptcha() {
        guard let challenge = captchaChallenge, let runtime else { return }
        Task {
            captchaDialogImage = try? await runtime.fetchCaptcha(
                challenge.imageUrl, refreshParam: challenge.refreshParam
            )
        }
    }

    func confirmCaptchaDialog() {
        guard let challenge = captchaChallenge,
              !captchaDialogInput.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        values[challenge.targetKey] = captchaDialogInput
        captchaChallenge = nil
        captchaDialogInput = ""
        captchaDialogImage = nil
        submit()
    }

    func dismissCaptchaDialog() {
        captchaChallenge = nil
        captchaDialogInput = ""
        captchaDialogImage = nil
    }

    /// “登录失败”弹窗的“重新登录”：清空一次性输入并换新图形验证码，把用户引导回
    /// 登录表单重新填写提交（扫码方式重新生成二维码），不直接重放旧请求。
    func retryAfterFailure() {
        failureDialog = nil
        guard let method = currentMethod() else { return }
        busy = false
        error = nil
        status = nil
        if method.kind == "qrcode" {
            qrImage = nil
            qrState = ""
            qrMessage = ""
            launchQr(method)
            return
        }
        for field in method.fields where field.type == "captcha" || field.type == "smsCode" {
            values[field.id] = ""
        }
        for field in method.fields where field.type == "captcha" {
            refreshCaptcha(field)
        }
    }

    func dismissFailure() {
        failureDialog = nil
    }

    func sendMfaCode() {
        guard let method = currentMethod(), let runtime, let challenge = mfaChallenge,
              !mfaBusy, mfaCooldown == 0 else { return }
        Task {
            mfaBusy = true
            mfaError = nil
            do {
                let result = try await runtime.sendChallenge(
                    methodId: method.id,
                    values: publicValues(),
                    checkboxes: checkboxes,
                    challengeId: challenge.id,
                    secretPassword: secretPassword()
                )
                mfaBusy = false
                if (result["ok"] as? Bool) == true {
                    let seconds = max((result["cooldownSeconds"] as? NSNumber)?.intValue ?? 60, 1)
                    startMfaCooldown(seconds)
                } else {
                    mfaError = (result["message"] as? String) ?? "验证码发送失败"
                }
            } catch {
                mfaBusy = false
                mfaError = error.localizedDescription
            }
        }
    }

    private func startMfaCooldown(_ seconds: Int) {
        mfaCooldownTask?.cancel()
        mfaCooldown = seconds
        mfaCooldownTask = Task {
            var remaining = seconds
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                remaining -= 1
                mfaCooldown = remaining
            }
        }
    }

    func confirmMfaChallenge() {
        guard let method = currentMethod(), let runtime, let challenge = mfaChallenge,
              !mfaBusy,
              !mfaCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            mfaBusy = true
            mfaError = nil
            do {
                let result = try await runtime.submitChallenge(
                    methodId: method.id,
                    values: publicValues(),
                    checkboxes: checkboxes,
                    challengeId: challenge.id,
                    code: mfaCode.trimmingCharacters(in: .whitespacesAndNewlines),
                    remember: mfaRemember,
                    secretPassword: secretPassword()
                )
                mfaBusy = false
                if result.ok {
                    mfaChallenge = nil
                    await persistAndFinish(sessionCookies: result.sessionCookies)
                } else {
                    if let challenge = result.challenge {
                        mfaChallenge = challenge
                    }
                    mfaError = result.message.isEmpty ? "安全验证码错误，请重试" : result.message
                }
            } catch {
                mfaBusy = false
                mfaError = error.localizedDescription
            }
        }
    }

    func dismissMfaChallenge() {
        mfaChallenge = nil
        mfaCode = ""
        mfaError = nil
        mfaBusy = false
        mfaCooldownTask?.cancel()
        mfaCooldown = 0
    }

    // MARK: - QR code

    private func launchQr(_ method: LoginScriptRuntime.Method) {
        submitTask?.cancel()
        submitTask = Task {
            var attempt = 0
            // JS 内部轮询本身会容错；外层网络整体不可用时最多重启 3 轮，随后弹失败框。
            while !Task.isCancelled, attempt < 3 {
                // 只有首张二维码尚未到达时才显示忙碌提示。submit 内部包含 JS 轮询循环，
                // 会持续到扫码成功/失败，期间不能一直占用 busy；轮询中的状态
                // （已扫码/已刷新/失效）由二维码面板的 qrMessage 展示。
                if qrImage == nil {
                    busy = true
                    error = nil
                    status = attempt == 0 ? "正在生成二维码…" : "正在重新生成二维码…"
                }
                do {
                    let result = try await runtime?.submit(
                        methodId: method.id,
                        values: [:],
                        checkboxes: checkboxes,
                        secretPassword: ""
                    )
                    busy = false
                    status = nil
                    guard let result else { return }
                    if result.ok {
                        await persistAndFinish(sessionCookies: result.sessionCookies)
                        return
                    }
                    failureDialog = result.message.isEmpty
                        ? "二维码登录失败，请重新登录" : result.message
                    return
                } catch {
                    busy = false
                    status = nil
                    attempt += 1
                    if attempt >= 3 {
                        failureDialog = "网络异常，二维码登录失败，请重新登录"
                        return
                    }
                    let backoff = min(1 << min(attempt - 1, 4), 16)
                    try? await Task.sleep(nanoseconds: UInt64(backoff) * 1_000_000_000)
                }
            }
        }
    }

    // MARK: - Events / secrets

    private func applyUIEvent(_ event: LoginScriptRuntime.UIEvent) {
        switch event {
        case .qr(let state, let message, let image):
            qrState = state
            qrMessage = message
            // 二维码图片一到达就结束“正在生成二维码”提示，不再等整个轮询提交返回。
            if let image {
                qrImage = image
                busy = false
                status = nil
            }
        case .toast(let message):
            status = message
        case .phase(let state, let message):
            qrState = state
            qrMessage = message
        }
    }

    /// 密码字段用占位符替换后再交给运行时；真实密码单独走 secret 通道。
    private func publicValues() -> [String: String] {
        guard let method = currentMethod() else { return values }
        // mapValues 的闭包只接收 value，键值对转换走 Dictionary(uniqueKeysWithValues:)。
        return Dictionary(uniqueKeysWithValues: values.map { key, value in
            (key, method.fields.contains { $0.id == key && $0.type == "password" }
                ? LoginScriptRuntime.passwordToken
                : value)
        })
    }

    private func secretPassword() -> String {
        guard let passwordField = currentMethod()?.fields.first(where: { $0.type == "password" }) else {
            return ""
        }
        return values[passwordField.id] ?? ""
    }

    private func persistAndFinish(sessionCookies: [HTTPCookie]) async {
        status = "正在进入…"
        await SessionStore.shared.waitForPendingClear()
        // 对应安卓 LoginCookieJar.persistSession()：沙箱 cookie 校验通过后才落入持久化存储。
        SessionStore.shared.saveCookies(sessionCookies)
        SessionStore.shared.restoreToCookieStorage()
        let ok = await SessionStore.shared.restoreToWebViewAndWait()
        guard ok else {
            error = "登录会话未能写入系统 WebView"
            busy = false
            status = nil
            return
        }
        // 保存密码关键词只由密码方式维护：勾选则用本次账号密码覆盖旧记录，未勾选则清除；
        // 短信/扫码方式没有密码字段，绝不能顺手删掉已保存的密码。
        if currentMethod()?.kind == "password" {
            let remember = checkboxes["rememberCredential"] ?? false
            let username = values["username"] ?? ""
            if remember && !username.trimmingCharacters(in: .whitespaces).isEmpty {
                onRemember(username, secretPassword())
            } else {
                onForget()
            }
        }
        busy = false
        status = nil
        onAuthenticated()
    }
}
