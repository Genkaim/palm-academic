import SwiftUI
import UIKit
import UserNotifications

@main
struct PalmAcademicApp: App {
    @StateObject private var state = AppState()
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            AppRoot(state: state)
        }
    }
}

/// Resolves the display mode against the system appearance and hands the resolved state on.
///
/// "跟随系统" is a nil `preferredColorScheme`, so the system drives the appearance; the app still
/// has to know which one won, because the reader's WebView and a few surfaces are told explicitly
/// rather than inheriting it.
private struct AppRoot: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        RootView()
            .environmentObject(state)
            .preferredColorScheme(state.themeMode.colorScheme)
            .tint(Color(red: 0.16, green: 0.44, blue: 0.85))
            .task { await state.bootstrap() }
            .onAppear { state.resolveTheme(with: systemScheme) }
            .onChange(of: systemScheme) { scheme in state.resolveTheme(with: scheme) }
            .onChange(of: state.themeMode) { _ in state.resolveTheme(with: systemScheme) }
    }
}

/// Restores the persisted session before the first frame so WKWebView requests are authenticated.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        SchoolCatalog.shared.initialize()
        SessionStore.shared.restoreToCookieStorage()
        PortalMonitor.shared.configureChannel()
        PortalBackgroundScheduler.register()
        UNUserNotificationCenter.current().delegate = NotificationCenterDelegate.shared
        return true
    }

    /// Supplies the scene configuration in code, which is the alternative to listing one in the
    /// Info.plist manifest (TN3187).
    ///
    /// iOS 27 refuses to launch an app built with the latest SDK that has neither. SwiftUI's `App`
    /// protocol already runs on scenes, but the check for that is made against this method and the
    /// manifest, so one of them has to answer.
    ///
    /// Returning a configuration with no delegate class leaves the window to SwiftUI, which owns
    /// the `WindowGroup` above. Naming a scene delegate here instead would take the window away
    /// from it, and this app has no `SceneDelegate` class to name.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        NotificationPreferences.shared.reschedule()
    }
}

/// Presents change notifications while the app is in the foreground.
final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCenterDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            switch state.phase {
            case .launching:
                ProgressView()
                    .controlSize(.large)
            case .signedOut:
                LoginView()
            case .signedIn:
                MainShellView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state.phase)
    }
}

/// Host for the home/settings content and the Android-parity floating bottom navigation.
/// Search belongs to that bottom surface so the home list stays content-only and keeps its scroll
/// position while a query is entered.
///
/// Both destinations stay mounted and the visible one is brought forward with `zIndex` rather than
/// drawn in a fixed order. Ordering by zIndex is what makes the switch real: a fixed ZStack order
/// puts the home list on top of the settings page, so the settings page could fade in underneath it
/// and stay invisible no matter what `selectedTab` said -- the tab animated, nothing changed.
struct MainShellView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The cross-fade, scoped to the two pages. The navigation bar opts out of it (it is an overlay
    /// now, so a transition written here would otherwise reach it through the modifier chain) and
    /// drives its own search animation instead.
    private var pageAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.24)
    }

    var body: some View {
        ZStack {
            HomeView()
                .opacity(state.selectedTab == .home ? 1 : 0)
                .allowsHitTesting(state.selectedTab == .home)
                .zIndex(state.selectedTab == .home ? 1 : 0)

            SettingsScreen()
                .opacity(state.selectedTab == .settings ? 1 : 0)
                .allowsHitTesting(state.selectedTab == .settings)
                .zIndex(state.selectedTab == .settings ? 1 : 0)
        }
        .animation(pageAnimation, value: state.selectedTab)
        .overlay(alignment: .bottom) {
            // An overlay rather than a third ZStack child: the bar is pinned to the bottom by the
            // alignment instead of by a full-height `Spacer`, so it no longer covers the whole
            // screen and cannot swallow touches meant for the page underneath it.
            FloatingHomeNavigation()
        }
        .overlay(alignment: .top) {
            if let notice = state.sessionNotice {
                noticeBanner(notice)
            }
        }
    }

    @ViewBuilder
    private func noticeBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
            Text(text)
                .font(.footnote)
                .lineLimit(2)
            Spacer()
            Button {
                state.dismissSessionNotice()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }
}
