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
/// The two destinations live in a `UIPageViewController` pager (see `PagingPageContainer`) rather
/// than in SwiftUI's paging `TabView`. With `.page(indexDisplayMode: .never)` the TabView only
/// honours a programmatic selection that is a direct `@State` binding; when the binding is derived
/// from an `ObservableObject` -- which is what sharing the selection with the floating bar
/// requires -- tapping the bar updated the value (the highlight slid, the press animation ran) but
/// the page never turned, on iOS 17 and 18. UIKit's pager is turned imperatively with
/// `setViewControllers`, so a bar tap always moves the page. Its data source keeps the horizontal
/// swipe gesture, both hosting controllers stay mounted for the life of the shell, so neither
/// page loses its scroll position or its navigation stack -- matching Android's `HorizontalPager`
/// for the same two destinations.
struct MainShellView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Bridges the tab bar's `LiquidTabItem` onto the pager's page index. The pages are keyed by
    /// index rather than by item so the selection type stays the primitive `Int` the pager takes.
    private var pageSelection: Binding<Int> {
        Binding(
            get: { state.selectedTab == .settings ? 1 : 0 },
            set: {
                state.selectedTab = $0 == 1 ? .settings : .home
                // The setter only runs for a settled swipe (bar taps write `selectedTab` directly),
                // mirroring Android closing the search surface once the settings page settles.
                if $0 == 1 && state.isSearchPresented { state.dismissSearch() }
            }
        )
    }

    /// Built once per update of the shell. Each page has the app state injected explicitly:
    /// a manually created `UIHostingController` does not inherit the SwiftUI environment of the
    /// view that creates it, so without the injection the pages would find no `AppState`.
    private var pagerPages: [AnyView] {
        [
            AnyView(HomeView().environmentObject(state)),
            AnyView(SettingsScreen().environmentObject(state))
        ]
    }

    var body: some View {
        PagingPageContainer(selection: pageSelection, pages: pagerPages, animated: !reduceMotion)
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

/// A two-page horizontal pager backed by UIKit's `UIPageViewController`.
///
/// Why not SwiftUI's paging `TabView`: programmatic selection changes are unreliable when the
/// binding is a custom `Binding` over shared (observable) state -- the binding updates but the
/// visible page does not, which read as "the bottom bar only plays its press/highlight animation".
/// `UIPageViewController.setViewControllers(_:direction:animated:)` is an imperative turn, so a
/// floating-bar tap always changes the page. The data source supplies the same two hosting
/// controllers on every request and keeps them retained for the whole life of the shell, which is
/// what preserves each page's scroll position and navigation stack across trips between tabs.
struct PagingPageContainer: UIViewControllerRepresentable {
    @Binding var selection: Int
    let pages: [AnyView]
    /// Whether button-driven turns animate. Swipe gestures are always interactive; this only
    /// covers the imperative turn, so the accessibility "reduce motion" setting can disable it.
    var animated: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: NSNumber(value: 0)]
        )
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        // The pages paint their own backgrounds (the grouped list surfaces); the pager itself
        // must not add a white strip behind the slide between them.
        controller.view.backgroundColor = .clear

        context.coordinator.controllers = pages.map { UIHostingController(rootView: $0) }
        context.coordinator.parent = self
        let initialIndex = clamped(selection)
        context.coordinator.currentIndex = initialIndex
        controller.setViewControllers(
            [context.coordinator.controllers[initialIndex]],
            direction: .forward,
            animated: false
        )
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // Keep the hosted SwiftUI trees current without recreating the controllers, which is what
        // preserves the pages' state.
        for (index, page) in pages.enumerated() where index < coordinator.controllers.count {
            coordinator.controllers[index].rootView = page
        }

        let target = clamped(selection)
        // A turn already in flight (or already on the target page) must not start a second turn:
        // two overlapping setViewControllers calls leave the pager and the binding disagreeing
        // about which page is showing.
        guard !coordinator.isProgrammaticTurn, target != coordinator.currentIndex else { return }
        guard let visible = controller.viewControllers?.first,
              let visibleIndex = coordinator.controllers.firstIndex(where: { $0 === visible }) else { return }
        let direction: UIPageViewController.NavigationDirection =
            target > visibleIndex ? .forward : .reverse
        coordinator.isProgrammaticTurn = true
        controller.setViewControllers(
            [coordinator.controllers[target]],
            direction: direction,
            animated: animated
        ) { finished in
            coordinator.isProgrammaticTurn = false
            // An non-animated turn reports finished == true immediately.
            if finished || !animated { coordinator.currentIndex = target }
        }
    }

    private func clamped(_ index: Int) -> Int {
        min(max(index, 0), max(pages.count - 1, 0))
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var controllers: [UIHostingController<AnyView>] = []
        /// The page the pager currently considers itself on. Drives both the data-source direction
        /// and the guard against redundant turns.
        var currentIndex = 0
        /// True while a button-driven turn animates, so a SwiftUI update landing mid-turn does not
        /// start another one.
        var isProgrammaticTurn = false
        fileprivate var parent: PagingPageContainer!

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let index = controllers.firstIndex(where: { $0 === viewController }),
                  index > 0 else { return nil }
            return controllers[index - 1]
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let index = controllers.firstIndex(where: { $0 === viewController }),
                  index + 1 < controllers.count else { return nil }
            return controllers[index + 1]
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            // Only a settled swipe writes the binding; a swipe that was dragged and released back
            // where it started reports completed == false.
            guard completed,
                  let visible = pageViewController.viewControllers?.first,
                  let index = controllers.firstIndex(where: { $0 === visible }) else { return }
            currentIndex = index
            parent.selection = index
        }
    }
}
