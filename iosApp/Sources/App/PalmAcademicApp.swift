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

/// Host for the tab bar and the home/settings content areas.
///
/// The destinations go in a system `TabView`. That is what produces the platform's own bottom bar:
/// on iOS 26 it is drawn with the system's Liquid Glass material, and the press, long-press and
/// destination-change animations come with it. A hand-built bar can copy the material but has to
/// reimplement all three behaviours, and they are what makes a bar feel like a bar.
///
/// The search control floats above it rather than living inside it. Android can put search on the
/// bar because its bar only exists on the home screen; this bar is present on every screen, so
/// search opens where the user already is.
struct MainShellView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $state.selectedTab) {
                HomeView()
                    .tag(LiquidTabItem.home)
                    .tabItem {
                        Label(LiquidTabItem.home.title, systemImage: LiquidTabItem.home.systemImage)
                    }
                SettingsScreen()
                    .tag(LiquidTabItem.settings)
                    .tabItem {
                        Label(LiquidTabItem.settings.title, systemImage: LiquidTabItem.settings.systemImage)
                    }
            }

            // Search results sit directly above the control that produced them. They are an overlay
            // rather than a destination because search is not a place -- it is a way of choosing one
            // of the places, and the destination that gets pushed is the one the user picked.
            if state.isBarSearching, state.isSearching {
                SearchResultsOverlay(
                    onSelect: { item in
                        state.endBarSearch()
                        state.pendingNavigation = item
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, Metric.aboveBar)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                BarSearchControl(
                    isSearching: $state.isBarSearching,
                    query: $state.searchQuery,
                    isDark: state.isDark
                )
                .padding(.trailing, 10)
                .zIndex(2)
            }
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
        /// Clearance above the floating search control.
        ///
        /// The system tab bar is 49pt of content plus the home indicator, which iOS reports as a 34pt
        /// bottom safe area on a home-button device. The control sits on top of that, so it needs the
        /// whole of it plus its own height and the air to clear it.
        static let aboveBar: CGFloat = 49 + 34 + 49 + 10
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