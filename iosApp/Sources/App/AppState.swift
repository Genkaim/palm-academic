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

    @Published private(set) var phase: Phase = .launching
    @Published var username = ""
    @Published var password = ""
    @Published var rememberPassword = false
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var selectedTab: LiquidTabItem = .home
    @Published var isDark = false
    @Published var showingLogin = false
    /// Drives the full-screen web login screen presented from the login form.
    @Published var showingWebLogin = false
    @Published private(set) var sessionNotice: String?

    private let auth = AuthRepository()
    private var credentialKey = ""

    var schools: [SchoolProfile] { SchoolCatalog.shared.options }
    var selectedSchool: SchoolProfile? { SchoolCatalog.shared.activeProfile }
    var definition: SchoolDefinition? { SchoolCatalog.shared.definition }

    func bootstrap() async {
        SchoolCatalog.shared.initialize()
        _ = SchoolCatalog.shared.loadDefinition()
        isDark = ThemePreferences.shared.isDark
        SessionStore.shared.restoreToCookieStorage()

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
        case .valid:
            onAuthenticationCompleted()
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
        phase = .signedOut
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
final class ThemePreferences {
    static let shared = ThemePreferences()
    private static let darkKey = "portal_theme_dark"
    private init() {}

    var isDark: Bool {
        get { UserDefaults.standard.bool(forKey: Self.darkKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.darkKey) }
    }
}