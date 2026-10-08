import Foundation
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
    @Published var rememberPassword = false
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var selectedTab: LiquidTabItem = .home
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

    private let auth = AuthRepository()
    private var credentialKey = ""

    var schools: [SchoolProfile] { SchoolCatalog.shared.options }
    var selectedSchool: SchoolProfile? { SchoolCatalog.shared.activeProfile }
    var definition: SchoolDefinition? { SchoolCatalog.shared.definition }
    var isSignedIn: Bool { phase == .signedIn }

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
        isDark = ThemePreferences.shared.mode == .dark
        SessionStore.shared.restoreToCookieStorage()

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
            onAuthenticationCompleted()
        }
    }

    /// Quietly revalidates without ever throwing the user back to the login page.
///
/// A retry is only worth doing while the user is still trusting this session. The badge stays
/// hidden on success, so a healthy network reads as "nothing happened".
func revalidateQuietlyPublic() async {
        await revalidateQuietly()
    }

private func revalidateQuietly() async {
        var attempt = 0
        let maxAttempts = 6
        while attempt < maxAttempts {
            attempt += 1
            // Backoff so we are not hammering the campus portal while it is having a bad moment.
            let delay = UInt64(min(8, attempt)) * 1_000_000_000
            try? await Task.sleep(nanoseconds: delay)
            switch await auth.validateSession() {
            case .valid:
                sessionStatus = .hidden
                sessionNotice = nil
                onAuthenticationCompleted()
                // Any mounted reader is showing a stale page right now (its WebView answered
                // "session expired" before this revalidation succeeded). Bumping a global
                // counter lets each open `MaterialPageScreen` reload against the restored
                // session without the user having to tap anything.
                await MainActor.run {
                    SessionRefreshBus.shared.bump()
                }
                return
            case .expired:
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
        sessionStatus = .unavailable("网络较慢，或当前网络无法访问教务系统")
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
            onAuthenticationCompleted()
        case .expired:
            if sessionTrusted {
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
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // Persist the credentials the moment the user commits to logging in. The previous code only
        // saved on success, which meant a network timeout on the very first login discarded the
        // password even though 记住密码 was on -- the next launch opened with empty fields and the
        // user had to type everything in again. Saving here lets the very next launch retry with
        // the remembered credentials, even if THIS attempt never reaches the home page.
        if rememberPassword {
            CredentialStore.save(username: user, password: password, schoolID: school.id)
        } else {
            CredentialStore.clear(schoolID: school.id)
        }

        do {
            try await auth.login(username: user, password: password)
            onAuthenticationCompleted()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func completeWebLogin() {
        onAuthenticationCompleted()
    }

    /// Returns from the web login screen without a usable session. The portal may well have
    /// rendered a page that looked signed in, so the failure is surfaced on the login form
    /// instead of silently dropping the user back into the app.
    func dismissWebLogin(message: String) {
        errorMessage = message
        showingWebLogin = false
    }

    func signOut(message: String? = nil) {
        SessionStore.shared.clear()
        PortalMonitor.shared.cancel()
        CredentialStore.clear(schoolID: SchoolCatalog.shared.selectedSchoolID)
        // The current school is no longer trusted: the user is on the login form with empty fields,
        // so any "trusted session" retry logic would be operating on credentials they explicitly
        // asked to forget. The flag is per-school, so the next time they pick a school and sign in
        // it is set fresh.
        SessionTrustStore.shared.trusted = false
        sessionTrusted = false
        username = ""
        password = ""
        rememberPassword = false
        errorMessage = message
        sessionNotice = nil
        sessionStatus = .hidden
        isSearchPresented = false
        searchQuery = ""
        phase = .signedOut
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
        isSearchPresented = true
    }

    func dismissSearch() {
        isSearchPresented = false
        searchQuery = ""
    }

    private func onAuthenticationCompleted() {
        NotificationPreferences.shared.clearAuthenticationFailureMarker()
        let schoolID = SchoolCatalog.shared.selectedSchoolID
        // Once the home page has answered valid, the credential is "good" until the user signs out
        // or switches school. Subsequent "网络超时" answers are treated as transient and do not
        // kick the user back to the login form.
        SessionTrustStore.shared.trusted = true
        sessionTrusted = true
        QuickEntryBaseline.request(schoolID: schoolID)
        NotificationPreferences.shared.reschedule()
        loadRememberedCredential()
        errorMessage = nil
        phase = .signedIn
    }

    /// Dismisses the banner shown after a session was kept despite the portal being unreachable.
    func dismissSessionNotice() {
        sessionNotice = nil
    }

    /// Port of `LoginViewModel.selectSchool`: switching clears the session because the previous
    /// cookie belongs to the old university origin.
    func selectSchool(_ school: SchoolProfile) {
        errorMessage = nil
        let changed = SchoolCatalog.shared.select(schoolID: school.id)
        // The pick persists the id, and this flag is what makes the next cold launch reopen the
        // form on the same school.
        hasSelectedSchool = SchoolCatalog.shared.hasSelectedSchool
        credentialKey = school.id
        loadRememberedCredential()
        // The trust flag is read through a projection over the current school, so it flips
        // automatically to "false" the moment `selectedSchoolID` changes. Mirror that into the
        // published field so the home badge does not show a retry button on a brand-new school.
        sessionTrusted = SessionTrustStore.shared.trusted
        if changed {
            PortalMonitor.shared.cancel()
            SessionStore.shared.clear()
            if phase == .signedIn {
                phase = .signedOut
                sessionNotice = "已切换学校，请重新登录"
            }
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

    private func loadRememberedCredential() {
        let schoolID = SchoolCatalog.shared.selectedSchoolID
        credentialKey = schoolID
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
    private static func usernameKey(_ schoolID: String) -> String { "credential_username_\(schoolID)" }
    private static func passwordKey(_ schoolID: String) -> String { "credential_password_\(schoolID)" }

    static func load(schoolID: String) -> (username: String, password: String)? {
        let defaults = UserDefaults.standard
        guard let username = defaults.string(forKey: usernameKey(schoolID)),
              let password = defaults.string(forKey: passwordKey(schoolID)),
              !password.isEmpty else { return nil }
        return (username, password)
    }

    static func save(username: String, password: String, schoolID: String) {
        let defaults = UserDefaults.standard
        defaults.set(username, forKey: usernameKey(schoolID))
        defaults.set(password, forKey: passwordKey(schoolID))
    }

    static func clear(schoolID: String) {
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
