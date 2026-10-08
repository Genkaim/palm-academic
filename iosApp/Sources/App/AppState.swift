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

    private let auth = AuthRepository()
    private var credentialKey = ""

    var schools: [SchoolProfile] { SchoolCatalog.shared.options }
    var selectedSchool: SchoolProfile? { SchoolCatalog.shared.activeProfile }
    var definition: SchoolDefinition? { SchoolCatalog.shared.definition }
    var isSignedIn: Bool { phase == .signedIn }

    func bootstrap() async {
        SchoolCatalog.shared.initialize()
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
            signOut(message: "登录已过期，请重新登录")
        case .unavailable:
            // Keep the cached session: an unreachable campus network is not a credential failure.
            sessionNotice = "暂时无法连接教务系统，已保留当前会话"
            sessionStatus = .unavailable("网络较慢，或当前网络无法访问教务系统")
        case .valid:
            onAuthenticationCompleted()
        }
    }

    /// Asks once whether the portal is reachable, so a refused local-network connection is visible
    /// in the settings rather than only showing up as a page that never loads.
    func probeNetwork() async {
        await LocalNetworkProbe.shared.probe()
    }

    /// Re-runs the session check behind the home screen's status badge, which is the Android
    /// `onRetry` action on the "验证失败，点击重试" state.
    func revalidateSession() async {
        guard sessionStatus != .checking else { return }
        sessionStatus = .checking
        switch await auth.validateSession() {
        case .valid:
            sessionStatus = .hidden
            sessionNotice = nil
        case .expired:
            signOut(message: "登录状态已失效")
        case .unavailable:
            sessionStatus = .unavailable("网络较慢，或当前网络无法访问教务系统")
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

        do {
            try await auth.login(username: user, password: password)
            if rememberPassword {
                CredentialStore.save(username: user, password: password, schoolID: school.id)
            } else {
                CredentialStore.clear(schoolID: school.id)
            }
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
        credentialKey = school.id
        loadRememberedCredential()
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
