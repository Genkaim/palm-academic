import Foundation
import Security
import SwiftUI
import UserNotifications

/// Port of the authentication and navigation state that Android spreads across `MainActivity`,
/// `LoginViewModel` and `PortalSessionCoordinator`.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case launching
        case signedOut
        case signedIn
    }

    /// Port of `PortalSessionCoordinator.state` as the home screen consumes it: a hidden state, a
    /// "checking" state that spins, and a failure the user can tap to retry. Android hides the
    /// badge for a healthy session rather than showing a confirmation.
    enum SessionStatus: Equatable {
        case hidden
        case checking
        case unavailable(String)
    }

    @Published private(set) var phase: Phase = .launching
    @Published var username = ""
    @Published var password = ""
    @Published var captcha = ""
    @Published private(set) var captchaImageData: Data?
    @Published private(set) var captchaLoading = false
    @Published private(set) var captchaError: String?
    @Published var rememberPassword = false
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// Non-terminal status shown while a network-caused password login is being retried, e.g.
    /// "网络不稳定，正在重试（第 3 次）…". Cleared as soon as login succeeds or the portal
    /// returns a definitive rejection (wrong password / captcha).
    @Published private(set) var loginRetryMessage: String?
    @Published var selectedTab: LiquidTabItem = .home
    /// Increments only after a new password/web login succeeds. Views use it as an identity so a
    /// logout/login cycle cannot revive the previous tab, navigation path or hidden prefetch state.
    @Published private(set) var authenticationGeneration = 0
    /// Whether the user has ever explicitly chosen a school, port of Android's
    /// `hasSelectedSchool`. The catalog always resolves an active profile (falling back to the
    /// built-in default), so this persisted flag -- not the non-nil profile -- is what tells the
    /// login screen to show the credential form with the LAST CHOSEN school rather than the
    /// first-run "pick a school" landing.
    @Published private(set) var hasSelectedSchool = SchoolCatalog.shared.hasSelectedSchool
    /// The Android client treats search as a transient state of the floating bottom navigation,
    /// rather than as a page. Keeping that state here lets the shell own focus and animation while
    /// `HomeView` owns only the filtering of its rows.
    @Published var isSearchPresented = false
    /// Search is a two-step request: HomeView first clears any pushed detail page, then acknowledges
    /// this generation on the next run-loop turn so the bottom glass field can expand.
    @Published private(set) var searchPresentationRequest = 0
    @Published var searchQuery = ""
    @Published private(set) var isDark = false
    /// The user's display-mode choice. `isDark` is derived from this and the current system
    /// appearance, so the two can never disagree.
    @Published var themeMode: ThemeMode = ThemePreferences.shared.mode
    @Published var showingLogin = false
    /// Drives the full-screen web login screen presented from the login form.
    @Published var showingWebLogin = false
    @Published private(set) var sessionNotice: String?
    @Published private(set) var sessionStatus: SessionStatus = .hidden
    /// True once the user has been seen to reach the home page with this session at least once.
    /// A "网络超时" that arrives while we are already trusted is NOT a credential failure -- it is
    /// just the campus network being slow -- so we keep the user where they are and quietly
    /// revalidate in the background instead of throwing them back to the login form. Mirrors
    /// Android's `SessionTrustStore`.
    @Published private(set) var sessionTrusted: Bool = SessionTrustStore.shared.trusted
    /// type=script 学校的 schema 驱动登录控制器（账号密码/短信/扫码，JS 沙箱）。
    /// 仅在当前学校定义使用脚本登录时存在；为 nil 时登录页走经典密码表单。
    @Published private(set) var scriptLogin: ScriptLoginController?

    private let auth = AuthRepository()
    /// The in-flight password-login retry loop. A new login attempt cancels the previous one so
    /// two loops cannot interleave their backoff and cookie writes.
    private var loginTask: Task<Void, Never>?
    private var captchaTask: Task<Void, Never>?
    /// Bumped on every explicit authentication success / content-arrived / sign-out. A quiet
    /// revalidation loop captures the value at entry and stops the moment it changes, so a loop
    /// that was started by a hidden reader's transient login-redirect can never surface a
    /// "checking" badge after the user has actually reached the home page or a real page.
    /// Mirrors Android cancelling `validationJob` in `markAuthenticated()`.
    private var sessionRevision = 0
    /// HomeView can be rebuilt whenever the user changes tabs or returns from a pushed page. Keep
    /// the automatic release-check claim at app-state lifetime instead of view lifetime so one app
    /// launch can show at most one automatic update prompt. Manual checks do not use this flag.
    private var automaticReleaseCheckClaimed = false

    var schools: [SchoolProfile] { SchoolCatalog.shared.options }
    var selectedSchool: SchoolProfile? { SchoolCatalog.shared.activeProfile }
    var definition: SchoolDefinition? { SchoolCatalog.shared.definition }
    var isSignedIn: Bool { phase == .signedIn }
    var captchaRequired: Bool { definition?.auth?.captcha?.required == true }
    var supportsSilentPasswordReauthentication: Bool {
        definition?.auth?.isWebOnly != true && !captchaRequired &&
            CredentialStore.load(schoolID: SchoolCatalog.shared.selectedSchoolID) != nil
    }

    func claimAutomaticReleaseCheck() -> Bool {
        guard !automaticReleaseCheckClaimed else { return false }
        automaticReleaseCheckClaimed = true
        return true
    }

    func refreshCaptchaIfNeeded() async {
        guard captchaRequired, phase != .signedIn else {
            captchaImageData = nil
            captchaError = nil
            captchaLoading = false
            return
        }
        captchaTask?.cancel()
        captcha = ""
        captchaImageData = nil
        captchaLoading = true
        captchaError = nil
        let task = Task { @MainActor in
            do {
                let data = try await auth.refreshCaptcha()
                guard !Task.isCancelled else { return }
                captchaImageData = data
                captchaLoading = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                captchaImageData = nil
                captchaLoading = false
                captchaError = "验证码加载失败，点按重试"
            }
        }
        captchaTask = task
        await task.value
    }

    func bootstrap() async {
        SchoolCatalog.shared.initialize()
        // Restore the persisted "a school was chosen" state so the login form opens on the last
        // selected school instead of the first-run landing.
        hasSelectedSchool = SchoolCatalog.shared.hasSelectedSchool
        // Restore the remembered credential BEFORE the signed-out early return below. The previous
        // placement only ran on the signed-in path, so a cold launch with no live session -- the
        // exact case the login form exists for -- always showed empty fields even though a
        // credential was saved, which read as "记住密码 does nothing".
        loadRememberedCredential()
        _ = SchoolCatalog.shared.loadDefinition()
        bindLoginMode()
        isDark = ThemePreferences.shared.mode == .dark
        SessionStore.shared.restoreToCookieStorage()

        if captchaRequired && NotificationPreferences.shared.captchaReauthenticationRequired {
            requireCaptchaReauthentication()
            return
        }

        // Ask while the school is known and before any page has been loaded. Two things hang on the
        // timing: the system raises its local-network prompt when something reaches for a campus
        // address and raises it at most once per install, so reaching early is what gets the
        // question asked at all; and reaching before the first load is what lets a later failure say
        // whether it was policy or merely the network.
        //
        // Deliberately not awaited. The probe abandons its attempt after a few seconds, and waiting
        // here would hand that timeout to the launch spinner -- a third of a minute before the app
        // decides whether it is signed in. Only the attempt has to happen now, not the answer.
        Task { await LocalNetworkProbe.shared.probe() }

        guard PortalHTTP.hasSessionCookie else {
            phase = .signedOut
            return
        }
        // A persisted cookie is the durable cold-start signal, so the home screen opens right away
        // and validation runs behind it.
        phase = .signedIn
        loadRememberedCredential()

        switch await auth.validateSession() {
        case .expired:
            if supportsSilentPasswordReauthentication {
                sessionNotice = "正在重新登录…"
                sessionStatus = .checking
                Task { await revalidateQuietly() }
                return
            }
            // A previously-trusted session that no longer answers is almost always a slow campus
            // network, not stolen credentials. Kick off a quiet retry loop instead of throwing the
            // user back to the login form.
            if sessionTrusted {
                sessionNotice = "正在重新验证教务会话…"
                sessionStatus = .checking
                Task { await revalidateQuietly() }
            } else {
                signOut(message: "登录已过期，请重新登录")
            }
        case .unavailable:
            // Keep the cached session: an unreachable campus network is not a credential failure.
            sessionNotice = "暂时无法连接教务系统，已保留当前会话"
            sessionStatus = .unavailable("网络较慢，或当前网络无法访问教务系统")
            if sessionTrusted {
                Task { await revalidateQuietly() }
            }
        case .valid:
            onAuthenticationCompleted(freshLogin: false)
        }
    }

    /// Quietly revalidates without ever throwing the user back to the login page.
///
/// A retry is only worth doing while the user is still trusting this session. The badge stays
/// hidden on success, so a healthy network reads as "nothing happened".
@discardableResult
func revalidateQuietlyPublic() async -> Bool {
        await revalidateQuietly()
        return phase == .signedIn && sessionStatus == .hidden
    }

private func revalidateQuietly() async {
        let revision = sessionRevision
        var attempt = 0
        let maxAttempts = 6
        while attempt < maxAttempts {
            // A login completed (or real content arrived) while we were waiting: the answer is
            // already in and this loop must not publish a stale badge afterwards.
            guard revision == sessionRevision else { return }
            attempt += 1
            // Backoff so we are not hammering the campus portal while it is having a bad moment.
            let delay = UInt64(min(8, attempt)) * 1_000_000_000
            try? await Task.sleep(nanoseconds: delay)
            guard revision == sessionRevision else { return }
            switch await auth.validateSession() {
            case .valid:
                guard revision == sessionRevision else { return }
                sessionStatus = .hidden
                sessionNotice = nil
                onAuthenticationCompleted(freshLogin: false)
                // Any mounted reader is showing a stale page right now (its WebView answered
                // "session expired" before this revalidation succeeded). Bumping a global
                // counter lets each open `MaterialPageScreen` reload against the restored
                // session without the user having to tap anything.
                await MainActor.run {
                    SessionRefreshBus.shared.bump()
                }
                return
            case .expired:
                guard revision == sessionRevision else { return }
                if supportsSilentPasswordReauthentication {
                    await reauthenticatePasswordQuietly(revision: revision)
                    return
                }
                // Server says no. Stopping the loop is the right call here -- retrying will not
                // change a real expired-session answer -- but a previously-trusted user still does
                // not get kicked out: the badge stays visible with a retry action so they can
                // re-authenticate at their pace.
                sessionStatus = .unavailable("登录已过期，点击重试登录")
                sessionNotice = "登录状态已失效"
                return
            case .unavailable:
                continue
            }
        }
        guard revision == sessionRevision else { return }
        sessionStatus = .unavailable("网络较慢，或当前网络无法访问教务系统")
    }

    private func reauthenticatePasswordQuietly(revision: Int) async {
        guard supportsSilentPasswordReauthentication,
              let credential = CredentialStore.load(schoolID: SchoolCatalog.shared.selectedSchoolID)
        else {
            sessionStatus = .unavailable("登录已过期，未保存可用于自动重登的密码")
            return
        }
        var attempt = 0
        while revision == sessionRevision && !Task.isCancelled {
            do {
                try await auth.login(username: credential.username, password: credential.password)
                guard revision == sessionRevision else { return }
                onAuthenticationCompleted(freshLogin: false)
                SessionRefreshBus.shared.bump()
                return
            } catch PortalError.loginRejected {
                sessionNotice = "自动登录失败"
                sessionStatus = .unavailable("密码已失效，点击重试登录")
                return
            } catch is CancellationError {
                return
            } catch {
                attempt += 1
                sessionNotice = "正在重新登录（第 \(attempt) 次）…"
                let delay = UInt64([1, 2, 4, 8, 16][min(attempt - 1, 4)]) * 1_000_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    /// Asks once whether the portal is reachable, so a refused local-network connection is visible
    /// in the settings rather than only showing up as a page that never loads.
    func probeNetwork() async {
        await LocalNetworkProbe.shared.probe()
    }

    /// Re-runs the session check behind the home screen's status badge, which is the Android
    /// `onRetry` action on the "验证失败，点击重试" state.
    ///
    /// A trusted session that fails the validation is given a quiet retry loop instead of a sign
    /// out: a "网络超时" right after the user was on the home page is the network, not the
    /// credentials, and bouncing them back to the login form is the wrong answer.
    func revalidateSession() async {
        guard sessionStatus != .checking else { return }
        sessionStatus = .checking
        switch await auth.validateSession() {
        case .valid:
            sessionStatus = .hidden
            sessionNotice = nil
            onAuthenticationCompleted(freshLogin: false)
        case .expired:
            if supportsSilentPasswordReauthentication {
                sessionNotice = "正在重新登录…"
                Task { await reauthenticatePasswordQuietly(revision: sessionRevision) }
            } else if sessionTrusted {
                sessionNotice = "登录状态已失效"
                sessionStatus = .unavailable("登录已过期，点击重试登录")
            } else {
                signOut(message: "登录状态已失效")
            }
        case .unavailable:
            if sessionTrusted {
                // Quiet retry. The badge stays in "checking" while we try.
                Task { await revalidateQuietly() }
            } else {
                sessionStatus = .unavailable("网络较慢，或当前网络无法访问教务系统")
            }
        }
    }

    func login() async {
        guard let school = selectedSchool else {
            errorMessage = "请选择学校"
            return
        }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !password.isEmpty else {
            errorMessage = "请输入账号和密码"
            return
        }
        if captchaRequired && captcha.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = "请输入验证码"
            return
        }
        loginTask?.cancel()
        isLoading = true
        errorMessage = nil
        loginRetryMessage = nil
        loginTask = Task {
            var attempt = 0
            // Keep trying until the portal itself rejects the credentials or demands a captcha.
            // Those two are the ONLY terminal outcomes (PortalError.loginRejected); anything
            // else -- timeout, dropped connection, 5xx, a follow-up SESSION cookie delayed by a
            // bad network -- is retried for ever with capped exponential backoff, exactly like
            // the Android client. The user is never bounced back to the form for a network error.
            while !Task.isCancelled {
                do {
                    try await auth.login(username: user, password: password, captcha: captcha)
                    // Match Android: only a completed login is allowed to replace the remembered
                    // secret. A typo or transient failed attempt must not overwrite the last
                    // working credential.
                    if rememberPassword {
                        CredentialStore.save(username: user, password: password, schoolID: school.id)
                    } else {
                        CredentialStore.clear(schoolID: school.id)
                    }
                    isLoading = false
                    loginRetryMessage = nil
                    onAuthenticationCompleted(freshLogin: true)
                    return
                } catch PortalError.loginRejected(let message) {
                    isLoading = false
                    loginRetryMessage = nil
                    errorMessage = message
                    if captchaRequired { await refreshCaptchaIfNeeded() }
                    return
                } catch is CancellationError {
                    return
                } catch {
                    attempt += 1
                    loginRetryMessage = "网络不稳定，正在重试（第 \(attempt) 次）…"
                    // 1s, 2s, 4s, 8s, then 16s for every later attempt.
                    let backoffSeconds = [1, 2, 4, 8, 16][min(attempt - 1, 4)]
                    try? await Task.sleep(nanoseconds: UInt64(backoffSeconds) * 1_000_000_000)
                }
            }
        }
        await loginTask?.value
    }

    func completeWebLogin() {
        showingWebLogin = false
        onAuthenticationCompleted(freshLogin: true)
    }

    /// Waits for a prior logout's asynchronous WebKit deletion before creating a login WebView.
    /// Otherwise the old deletion callback can run after the new page has set SESSION and erase it.
    func beginWebLogin() async {
        await SessionStore.shared.waitForPendingClear()
        showingWebLogin = true
    }

    func setRememberPassword(_ enabled: Bool) {
        rememberPassword = enabled
        if !enabled {
            CredentialStore.clear(schoolID: SchoolCatalog.shared.selectedSchoolID)
        }
    }

    /// Port of Android's `PortalSessionCoordinator.markAuthenticated()`.
    ///
    /// Called the moment any reader renders real content: the session demonstrably works, so any
    /// in-flight validation/quiet-retry is cancelled and the home badge is cleared. Without this,
    /// a hidden prefetcher's transient redirect to the login page could leave the "登录中" badge
    /// spinning on the home screen right after a successful login.
    func markSessionReady() {
        sessionRevision &+= 1
        sessionStatus = .hidden
        sessionNotice = nil
    }

    /// Returns from the web login screen without a usable session. The portal may well have
    /// rendered a page that looked signed in, so the failure is surfaced on the login form
    /// instead of silently dropping the user back into the app.
    func dismissWebLogin(message: String) {
        errorMessage = message
        showingWebLogin = false
    }

    func signOut(message: String? = nil) {
        loginTask?.cancel()
        isLoading = false
        loginRetryMessage = nil
        SessionStore.shared.clear()
        PortalMonitor.shared.cancel()
        // Signing out ends the session but does not mean "forget my saved password". Android keeps
        // the encrypted credential too; the login form reloads it below, while toggling 记住密码 off
        // remains the explicit deletion action.
        SessionTrustStore.shared.trusted = false
        sessionTrusted = false
        loadRememberedCredential()
        errorMessage = message
        showingWebLogin = false
        // Retire any quiet-retry loop so it cannot republish a badge over the login form.
        markSessionReady()
        isSearchPresented = false
        searchQuery = ""
        selectedTab = .home
        phase = .signedOut
    }

    func requireCaptchaReauthentication() {
        guard captchaRequired, definition?.auth?.isWebOnly != true else { return }
        NotificationPreferences.shared.markCaptchaReauthenticationRequired()
        signOut(message: "登录已过期，请输入验证码重新登录")
        Task { await refreshCaptchaIfNeeded() }
    }

    // MARK: - Search

    /// Resolves the display mode against the current system appearance. The root view calls this
    /// whenever either changes, so a 跟随系统 selection tracks the system without the app having to
    /// observe anything itself.
    func resolveTheme(with systemScheme: ColorScheme) {
        switch themeMode {
        case .system: isDark = systemScheme == .dark
        case .light: isDark = false
        case .dark: isDark = true
        }
        ThemePreferences.shared.mode = themeMode
    }

    /// The query actually used for filtering, matching Android's `query.trim()`.
    var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the home screen is showing search results rather than its normal content.
    var isSearching: Bool {
        !trimmedSearchQuery.isEmpty
    }

    func clearSearch() {
        searchQuery = ""
    }

    func presentSearch() {
        selectedTab = .home
        searchPresentationRequest &+= 1
    }

    func completeSearchPresentation(_ request: Int) {
        guard request == searchPresentationRequest else { return }
        isSearchPresented = true
    }

    func dismissSearch() {
        isSearchPresented = false
        searchQuery = ""
    }

    private func onAuthenticationCompleted(freshLogin: Bool) {
        NotificationPreferences.shared.clearAuthenticationFailureMarker()
        let schoolID = SchoolCatalog.shared.selectedSchoolID
        // Once the home page has answered valid, the credential is "good" until the user signs out
        // or switches school. Subsequent "网络超时" answers are treated as transient and do not
        // kick the user back to the login form.
        SessionTrustStore.shared.trusted = true
        sessionTrusted = true
        if freshLogin {
            // Never show data produced under the previous session/account. The new shell starts on
            // Home, mounts a fresh baseline warmer, and fetches all declared redrawn pages again.
            MaterialPageCache.clearAll()
            QuickEntryBaseline.request(schoolID: schoolID)
            // Do not let the previous account's automatic-run timestamp suppress this account's
            // first scheduled comparison after its new four-page baseline has been established.
            PortalPollTiming.resetForFreshSession()
            selectedTab = .home
            isSearchPresented = false
            searchQuery = ""
            authenticationGeneration &+= 1
        }
        NotificationPreferences.shared.reschedule()
        loadRememberedCredential()
        errorMessage = nil
        // Clear any badge/checking state left by a previous school's session or by a reader's
        // redirect, and retire any quiet-retry loop. Android's `markAuthenticated()` does exactly
        // this -- without it the home screen still flashed "尝试登录…" after a finished login.
        markSessionReady()
        phase = .signedIn
    }

    /// Port of `LoginViewModel.selectSchool`: switching clears the session because the previous
    /// cookie belongs to the old university origin.
    func selectSchool(_ school: SchoolProfile) {
        captchaTask?.cancel()
        auth.discardPreparedLogin()
        captcha = ""
        captchaImageData = nil
        captchaError = nil
        errorMessage = nil
        let changed = SchoolCatalog.shared.select(schoolID: school.id)
        // The pick persists the id, and this flag is what makes the next cold launch reopen the
        // form on the same school.
        hasSelectedSchool = SchoolCatalog.shared.hasSelectedSchool
        loadRememberedCredential()
        // 学校切换后登录方式可能不同（salted-sha1/web/script），重建脚本登录控制器。
        scriptLogin?.close()
        scriptLogin = nil
        bindLoginMode()
        // The trust flag is read through a projection over the current school, so it flips
        // automatically to "false" the moment `selectedSchoolID` changes. Mirror that into the
        // published field so the home badge does not show a retry button on a brand-new school.
        sessionTrusted = SessionTrustStore.shared.trusted
        if changed {
            PortalMonitor.shared.cancel()
            SessionStore.shared.clear()
            if phase == .signedIn {
                // Switching schools invalidates the prior session and needs the login form to
                // re-bind to the new school. The banner the previous version pushed
                // (`sessionNotice = "已切换学校，请重新登录"`) surfaced inside the shell as an
                // extra top-of-screen overlay the user had to dismiss; the login form itself
                // already explains the situation once it appears, so the second surface was
                // redundant and noisy.
                phase = .signedOut
            }
        }
        if captchaRequired, phase != .signedIn {
            Task { await refreshCaptchaIfNeeded() }
        }
    }

    func refreshFromGitHub() async {
        do {
            let result = try await SchoolCatalog.shared.refreshFromGitHub()
            _ = SchoolCatalog.shared.loadDefinition()
            sessionNotice = "已更新 \(result.schoolCount) 所学校配置（\(result.downloadedFileCount) 个文件）"
        } catch {
            errorMessage = "更新失败：\(error.localizedDescription)"
        }
    }

    /// Port of `MainActivity.bindLoginMode`：当前学校为 type=script 时挂载脚本登录控制器
    /// （账号密码/短信/扫码），其它登录方式回到经典密码表单。
    private func bindLoginMode() {
        let loadedDefinition = SchoolCatalog.shared.loadDefinition()
        guard loadedDefinition?.auth?.usesScript == true else {
            scriptLogin?.close()
            scriptLogin = nil
            return
        }
        guard scriptLogin == nil else { return }
        let remembered = CredentialStore.load(schoolID: SchoolCatalog.shared.selectedSchoolID)
        let controller = ScriptLoginController(
            onAuthenticated: { [weak self] in
                self?.onAuthenticationCompleted(freshLogin: true)
            },
            onRemember: { username, password in
                CredentialStore.save(
                    username: username,
                    password: password,
                    schoolID: SchoolCatalog.shared.selectedSchoolID
                )
            },
            onForget: {
                CredentialStore.clear(schoolID: SchoolCatalog.shared.selectedSchoolID)
            }
        )
        scriptLogin = controller
        if let remembered, !remembered.username.isEmpty {
            // 预填账号必须在 start() 之前：bindMethod 会保留已有 username 并清空其余字段，
            // 之后再写入可能与 schema 绑定发生竞态。密码只保存在钥匙串，不进入脚本值表。
            controller.setValue("username", remembered.username)
        }
        if let loadedDefinition { controller.start(definition: loadedDefinition) }
    }

    private func loadRememberedCredential() {
        let schoolID = SchoolCatalog.shared.selectedSchoolID
        if let credential = CredentialStore.load(schoolID: schoolID) {
            username = credential.username
            password = credential.password
            rememberPassword = true
        } else {
            username = ""
            password = ""
            rememberPassword = false
        }
    }
}

/// Port of `PasswordCredentialStore` from `PasswordCredentialStore.kt`.
enum CredentialStore {
    private struct Payload: Codable {
        let username: String
        let password: String
    }

    private static let service = "\(Bundle.main.bundleIdentifier ?? "cn.edu.cupk.portalreader").remembered-password"
    private static func usernameKey(_ schoolID: String) -> String { "credential_username_\(schoolID)" }
    private static func passwordKey(_ schoolID: String) -> String { "credential_password_\(schoolID)" }

    static func load(schoolID: String) -> (username: String, password: String)? {
        var result: CFTypeRef?
        var query = baseQuery(schoolID: schoolID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let payload = try? JSONDecoder().decode(Payload.self, from: data),
           !payload.username.isEmpty,
           !payload.password.isEmpty {
            return (payload.username, payload.password)
        }

        // One-time migration from the earlier plaintext UserDefaults implementation.
        let defaults = UserDefaults.standard
        guard let username = defaults.string(forKey: usernameKey(schoolID)),
              let password = defaults.string(forKey: passwordKey(schoolID)),
              !username.isEmpty,
              !password.isEmpty else { return nil }
        save(username: username, password: password, schoolID: schoolID)
        return (username, password)
    }

    static func save(username: String, password: String, schoolID: String) {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty,
              let data = try? JSONEncoder().encode(Payload(username: trimmed, password: password)) else { return }
        let query = baseQuery(schoolID: schoolID)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        let finalStatus: OSStatus
        if updateStatus == errSecItemNotFound {
            var inserted = query
            attributes.forEach { inserted[$0.key] = $0.value }
            finalStatus = SecItemAdd(inserted as CFDictionary, nil)
        } else {
            finalStatus = updateStatus
        }
        // During migration, retain the legacy value if Keychain is temporarily unavailable. The
        // next launch can retry instead of silently losing a credential the user chose to keep.
        if finalStatus == errSecSuccess {
            clearLegacy(schoolID: schoolID)
        }
    }

    static func clear(schoolID: String) {
        SecItemDelete(baseQuery(schoolID: schoolID) as CFDictionary)
        clearLegacy(schoolID: schoolID)
    }

    private static func baseQuery(schoolID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: schoolID
        ]
    }

    private static func clearLegacy(schoolID: String) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: usernameKey(schoolID))
        defaults.removeObject(forKey: passwordKey(schoolID))
    }
}

/// Port of the theme preference handling in `PortalTheme.kt`.
/// Port of `PortalThemeMode`: the three display modes the Android settings page offers.
///
/// Android stores the choice as an enum and derives the dark flag from it. iOS needs the same
/// three states, and "follow the system" is the one that changes how the app is built rather than
/// what it paints: a nil `preferredColorScheme` is what lets the system drive, which the previous
/// two-state toggle could not express.
enum ThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// Nil means "do not constrain the system", which is how SwiftUI expresses 跟随系统.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

final class ThemePreferences {
    static let shared = ThemePreferences()
    private static let modeKey = "portal_theme_mode"
    private init() {}

    var mode: ThemeMode {
        get {
            (UserDefaults.standard.string(forKey: Self.modeKey)).flatMap(ThemeMode.init(rawValue:)) ?? .system
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.modeKey) }
    }

    /// Whether the app is currently painting dark, whichever mode got it there.
    var isDark: Bool { mode == .dark }
}

/// Port of `SessionTrustStore` from `SessionTrustStore.kt`.
///
/// One boolean per school, written when the home page has answered valid for that school and
/// cleared when the user signs out or switches to a school that has not been validated yet.
/// "Trusted" means "the password was good on a recent visit" -- not "the cookie is still alive",
/// which is what `SessionStore` already owns -- so a network timeout after a trusted visit
/// is treated as transient and does not kick the user back to the login form.
/// `MainActor` because its `currentSchool` projection reads a `SchoolCatalog` value, and the
/// catalog is itself main-actor isolated. The trust flag is only ever poked from `AppState`
/// during a sign-in, sign-out or school switch, which are already main-actor entry points, so
/// the isolation lines up with the call sites without any extra hops.
@MainActor
final class SessionTrustStore {
    static let shared = SessionTrustStore()
    private static let key = "session_trust_school"
    private init() {}

    /// The school id this trust flag is keyed to. Reading and writing go through this projection so
    /// a stale value from a previous school never leaks across a switch.
    private var currentSchool: String {
        SchoolCatalog.shared.selectedSchoolID
    }

    var trusted: Bool {
        get {
            let defaults = UserDefaults.standard
            return defaults.string(forKey: Self.key) == currentSchool
        }
        set {
            let defaults = UserDefaults.standard
            if newValue {
                defaults.set(currentSchool, forKey: Self.key)
            } else if defaults.string(forKey: Self.key) == currentSchool {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }
}

/// Broadcasts the moment a trusted session was restored after a quiet revalidation. Every open
/// `MaterialPageScreen` listens for this and bumps its own `refreshToken`, so a WebView that was
/// showing the portal's login redirect switches over to the real page without the user having
/// to tap refresh themselves.
@MainActor
final class SessionRefreshBus {
    static let shared = SessionRefreshBus()
    /// Notification name used to forward a bump event to observers.
    static let didRefreshNotification = Notification.Name("SessionRefreshBus.didRefresh")
    private init() {}

    /// Bumped count of background revalidations that have completed. Pages keep the latest value
    /// they've seen and react to changes, so an observer set up after a bump simply receives the
    /// next one -- no missed events.
    private(set) var count: Int = 0

    func bump() {
        count &+= 1
        NotificationCenter.default.post(name: Self.didRefreshNotification, object: nil)
    }
}
