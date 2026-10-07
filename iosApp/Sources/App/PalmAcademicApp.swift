import SwiftUI
import UIKit
import UserNotifications

@main
struct PalmAcademicApp: App {
    @StateObject private var state = AppState()
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .preferredColorScheme(state.isDark ? .dark : .light)
                .tint(Color(red: 0.16, green: 0.44, blue: 0.85))
                .task { await state.bootstrap() }
        }
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

/// Host for the hand-drawn liquid glass tab bar and the four native content areas.
struct MainShellView: View {
    @EnvironmentObject private var state: AppState
    @State private var actionItem: PortalItem?

    private var tabs: [LiquidTabItem] {
        [.home, .quick, .notices, .settings]
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // The tab's own root view has to sit in the stack, not in an overlay. An overlay is
            // proposed whatever size the ZStack ends up with, and a NavigationStack given no height
            // collapses: its bar still draws, its content does not, and because the ZStack then
            // measures zero the bottom-aligned tab bar rises into the middle of the screen. Each tab
            // root is self-contained -- HomeView and QuickEntriesView each own a NavigationStack --
            // so switching tabs legitimately rebuilds the stack.
            ZStack {
                content(for: state.selectedTab)
            }

            // The glass bar floats above the content so both tabs stay scrollable underneath.
            LiquidTabBar(
                items: tabs,
                selection: $state.selectedTab,
                isDark: state.isDark
            )
            .padding(.bottom, 4)
        }
        .overlay(alignment: .top) {
            if let notice = state.sessionNotice {
                noticeBanner(notice)
            }
        }
    }

    @ViewBuilder
    private func content(for tab: LiquidTabItem) -> some View {
        switch tab.id {
        case LiquidTabItem.home.id: HomeView()
        case LiquidTabItem.quick.id: QuickEntriesView()
        case LiquidTabItem.notices.id: NoticeHistoryScreen()
        case LiquidTabItem.settings.id: SettingsScreen()
        default: EmptyView()
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