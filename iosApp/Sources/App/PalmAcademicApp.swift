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
/// The two destinations live in a paging `TabView` rather than as two opacity-faded children of a
/// `ZStack`. Both of the obvious alternatives fail here. Stacking them by opacity does not switch,
/// because each page has its own `NavigationStack` and iOS backs those with a UIKit navigation
/// controller whose z-order SwiftUI does not control -- `zIndex` is ignored for them, so the home
/// page stays painted on top and the settings page fades in underneath it. Dropping to a plain
/// `if/else` would switch, but it would destroy the home list's scroll position and its navigation
/// stack on every trip to the settings. The paging container keeps both mounted, keeps the
/// selection binding authoritative, and matches Android's `HorizontalPager` for the same two
/// destinations.
struct MainShellView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Bridges the tab bar's `LiquidTabItem` onto the container's page index. The pages are tagged
    /// by index rather than by item so the selection type stays the primitive `Int` the container
    /// expects.
    private var pageSelection: Binding<Int> {
        Binding(
            get: { state.selectedTab == .settings ? 1 : 0 },
            set: { state.selectedTab = $0 == 1 ? .settings : .home }
        )
    }

    var body: some View {
        TabView(selection: pageSelection) {
            HomeView()
                .tag(0)
            SettingsScreen()
                .tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .overlay(alignment: .bottom) {
            // An overlay rather than a third child: the bar is pinned by its own alignment instead
            // of by a full-height `Spacer`, so it never covers the page or swallows its touches.
            FloatingHomeNavigation()
        }
        .overlay(alignment: .top) {
            if let notice = state.sessionNotice {
                noticeBanner(notice)
            }
        }
        .background {
            // The baseline fetch lives here rather than inside `HomeView`. It is what populates the
            // cache every page reads on entry, so tying it to the home page meant the warm-up never
            // happened for anyone who signed in and went straight to the settings tab -- and the
            // pages then had nothing to show until they were opened one at a time. It is invisible,
            // hit-testing is off, and it reads the same state either way.
            QuickEntryBaselinePrefetch()
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
