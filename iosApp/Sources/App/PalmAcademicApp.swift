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

/// Host for the liquid glass bar and the home/settings content areas.
struct MainShellView: View {
    @EnvironmentObject private var state: AppState

    /// The height the floating bar occupies, reserved at the bottom of every scrolling page so the
    /// bar never covers the last row. Without this the settings page's 退出登录 row sits underneath
    /// the capsule and cannot be tapped.
    private let barClearance: CGFloat = 92

    var body: some View {
        ZStack(alignment: .bottom) {
            // The tab's own root view has to sit in the stack, not in an overlay. An overlay is
            // proposed whatever size the ZStack ends up with, and a NavigationStack given no height
            // collapses: its bar still draws, its content does not, and because the ZStack then
            // measures zero the bottom-aligned bar rises into the middle of the screen.
            ZStack {
                content(for: state.selectedTab)
                    // Reserves room at the bottom of every scrolling page so the floating bar never
                    // covers the last row. A safe-area inset is used rather than a padding because
                    // a padding would shorten the page's own background; the inset scrolls with the
                    // content, which is what makes the last row reachable.
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear.frame(height: barClearance)
                    }
            }

            // Search results float directly above the bar. They are an overlay rather than a
            // destination because search is not a place -- it is a way of choosing one of the
            // places, and the destination that gets pushed is the one the user picked.
            if state.isBarSearching, state.isSearching {
                SearchResultsOverlay(
                    onSelect: { item in
                        state.endBarSearch()
                        state.selectedTab = .home
                        state.pendingNavigation = item
                    },
                    onDismiss: { state.endBarSearch() }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, Metric.barTotalHeight)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }

            // The bar floats above the content so the page stays scrollable underneath.
            LiquidBottomBar(
                isDark: state.isDark,
                selection: $state.selectedTab,
                isSearching: $state.isBarSearching,
                searchQuery: $state.searchQuery
            )
            .zIndex(2)
        }
        .overlay(alignment: .top) {
            if let notice = state.sessionNotice {
                noticeBanner(notice)
            }
        }
        .animation(
            .interpolatingSpring(stiffness: 440, damping: 34),
            value: state.isBarSearching
        )
    }

    private enum Metric {
        /// Bar height 64 + bottom padding 8 + the 20pt of breathing room above it.
        static let barTotalHeight: CGFloat = 92
    }

    @ViewBuilder
    private func content(for tab: LiquidTabItem) -> some View {
        switch tab.id {
        case LiquidTabItem.home.id: HomeView()
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