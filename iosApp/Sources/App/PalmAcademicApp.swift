import Combine
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

/// Host for the signed-in content: the home/settings pager plus the floating bottom navigation
/// both live inside `MainShellContainer` (see `MainShellViewController` for why UIKit owns them),
/// while the transient banner and the hidden baseline warmer stay SwiftUI-side.
struct MainShellView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MainShellContainer(state: state, animated: !reduceMotion)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            // Fades the status bar out as the search pill takes over the bar, then back in when
            // it closes. The system's own search experience behaves the same way: when the search
            // surface opens, the chrome around it (including the status bar) recedes. Driving the
            // fade off the same `isSearchPresented` flag the bar uses keeps the two in lockstep.
            //
            // The animation parameter to `statusBarHidden` is iOS 17+, and the deployment target is
            // 16.0; the system already cross-fades the bar on value change, so the absence is purely
            // cosmetic and matches what the spring backdrop on the search pill already provides.
            .statusBarHidden(state.isSearchPresented)
            .background {
                // The baseline fetch lives here rather than inside `HomeView`. It is what populates the
                // cache every page reads on entry, so tying it to the home page meant the warm-up never
                // happened for anyone who signed in and went straight to the settings tab -- and the
                // pages then had nothing to show until they were opened one at a time. It is invisible,
                // hit-testing is off, and it reads the same state either way.
                QuickEntryBaselinePrefetch()
            }
    }
}

/// Carries `AppState` into the shell and keeps its motion preference current. All of the
/// interesting behaviour lives in `MainShellViewController`.
struct MainShellContainer: UIViewControllerRepresentable {
    let state: AppState
    /// Whether button-driven turns animate. Swipe gestures are always interactive; this only
    /// covers the imperative turn, so the accessibility "reduce motion" setting can disable it.
    var animated: Bool = true

    func makeUIViewController(context: Context) -> MainShellViewController {
        MainShellViewController(state: state, animated: animated)
    }

    func updateUIViewController(_ controller: MainShellViewController, context: Context) {
        controller.animated = animated
    }
}

/// A two-page horizontal pager plus the floating bottom navigation, owned by one UIKit view
/// controller.
///
/// Two arrangements were tried and rejected. SwiftUI's paging `TabView` only honours a
/// programmatic selection that is a direct `@State` binding; with the selection derived from an
/// `ObservableObject` -- which sharing it with the floating bar requires -- a bar tap updated the
/// value but never turned the page on iOS 17/18. And a SwiftUI `.overlay` holding the bar above a
/// `UIPageViewController` stopped delivering taps to the bar at all on device: the pager's scroll
/// view wins the touch before the overlay sees it.
///
/// This shell sidesteps both. The pager is a child view controller; the bar lives in a second
/// hosting controller whose view is added LAST, making it the topmost subview. Taps are then
/// decided by ordinary UIKit hit-testing: a `_UIHostingView` returns nil where SwiftUI reports no
/// hit, so touches beside the pills fall through to the pager and the pills themselves always
/// receive theirs. Page turns are driven by a Combine subscription to `selectedTab`, delivered on
/// a later runloop pass than the tap -- an imperative `setViewControllers` outside any SwiftUI
/// update transaction -- while the data source keeps the horizontal swipe gesture. Both page
/// hosting controllers stay mounted for the life of the shell, so neither page loses its scroll
/// position or its navigation stack, matching Android's `HorizontalPager`.
@MainActor
final class MainShellViewController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    /// Mirrors the tint `AppRoot` applies on the SwiftUI side; manually created hosting
    /// controllers do not inherit it.
    private static let appTint = Color(red: 0.16, green: 0.44, blue: 0.85)

    private let state: AppState
    /// Button-driven turns only; swipe gestures are always interactive. Reduce-motion flips this
    /// off.
    var animated: Bool

    private let pager: UIPageViewController
    private let pageControllers: [UIHostingController<AnyView>]
    private let barHost: UIHostingController<AnyView>
    private var barBottomConstraint: NSLayoutConstraint!

    private var selectionCancellable: AnyCancellable?
    private var keyboardObserver: NSObjectProtocol?

    /// The page the pager currently considers itself on. Drives the guard against redundant turns.
    private var currentIndex: Int
    /// True while a button-driven turn animates, so a second tap landing mid-turn does not start
    /// another one.
    private var isTurning = false

    init(state: AppState, animated: Bool) {
        self.state = state
        self.animated = animated
        pager = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: NSNumber(value: 0)]
        )
        // Each page -- and the bar -- gets the app state injected explicitly: a manually created
        // `UIHostingController` does not inherit the SwiftUI environment of whatever presented the
        // shell, so without the injection these trees would find no `AppState`. The app tint is
        // injected the same way, or accent-coloured chrome (the selected tab, links) would fall
        // back to the system blue.
        //
        // Both pages also ignore the keyboard safe area: the shell lifts the bar itself when the
        // search keyboard appears, and letting the hosted list avoid the keyboard as well moved the
        // home content twice (once per owner). With this on the page, the list stays put and only
        // the bar rises.
        pageControllers = [
            UIHostingController(rootView: AnyView(
                HomeView()
                    .environmentObject(state)
                    .tint(Self.appTint)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            )),
            UIHostingController(rootView: AnyView(
                SettingsScreen()
                    .environmentObject(state)
                    .tint(Self.appTint)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            ))
        ]
        barHost = UIHostingController(rootView: AnyView(
            FloatingHomeNavigation()
                .environmentObject(state)
                .tint(Self.appTint)
                .ignoresSafeArea(.keyboard, edges: .bottom)
        ))
        currentIndex = state.selectedTab == .settings ? 1 : 0
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainShellViewController is created in code")
    }

    deinit {
        if let keyboardObserver {
            NotificationCenter.default.removeObserver(keyboardObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The shell owns the one continuous page colour behind every translucent layer. The
        // pager, each hosted page and the bar host all stay clear, so this colour reaches the
        // status-bar gutter and the home-indicator gutter without an opaque UIKit stripe cutting
        // either one off. `systemGroupedBackground` is dynamic, so it tracks light/dark mode.
        view.backgroundColor = UIColor.systemGroupedBackground

        pager.dataSource = self
        pager.delegate = self
        // The pages paint their own backgrounds (the grouped list surfaces); the pager itself must
        // not add a white strip behind the slide between them. `isOpaque = false` is set as well:
        // a clear `backgroundColor` on a view still flagged opaque can still composite a black
        // gutter during the slide between pages.
        pager.view.backgroundColor = .clear
        pager.view.isOpaque = false
        // Hosting views otherwise default to an opaque system background, which paints a solid
        // block behind the status bar and the home indicator even though the SwiftUI content is
        // transparent there.
        for controller in pageControllers {
            controller.view.backgroundColor = .clear
            controller.view.isOpaque = false
        }
        addChild(pager)
        pager.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pager.view)
        NSLayoutConstraint.activate([
            pager.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pager.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pager.view.topAnchor.constraint(equalTo: view.topAnchor),
            pager.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        pager.didMove(toParent: self)
        pager.setViewControllers([pageControllers[currentIndex]], direction: .forward, animated: false)

        barHost.view.backgroundColor = .clear
        barHost.view.isOpaque = false
        // The bar sizes itself to its content height and stays pinned to the shell's bottom edge;
        // the keyboard handler moves that constraint when the search field is focused.
        barHost.sizingOptions = [.intrinsicContentSize]
        addChild(barHost)
        barHost.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(barHost.view)
        barBottomConstraint = barHost.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            barHost.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            barHost.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            barBottomConstraint
        ])
        barHost.view.setContentHuggingPriority(.required, for: .vertical)
        barHost.view.setContentCompressionResistancePriority(.required, for: .vertical)
        barHost.didMove(toParent: self)

        // `receive(on:)` defers the turn out of the runloop pass that committed the tap, so the
        // imperative `setViewControllers` is never nested inside a SwiftUI animation transaction.
        selectionCancellable = state.$selectedTab
            .receive(on: RunLoop.main)
            .sink { [weak self] tab in
                self?.turn(to: tab == .settings ? 1 : 0)
            }

        // The bar host is a plain sibling view, so SwiftUI's keyboard safe area never reaches it;
        // it is lifted by hand, tracking the keyboard's own frame notifications. Hiding reports an
        // off-screen end frame through the same notification, which collapses the overlap to zero.
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.applyKeyboardFrame(notification)
        }
    }

    // MARK: - Turning

    private func turn(to index: Int) {
        guard !isTurning, index != currentIndex, pageControllers.indices.contains(index) else { return }
        let direction: UIPageViewController.NavigationDirection = index > currentIndex ? .forward : .reverse
        isTurning = true
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            isTurning = false
            currentIndex = index
        }
        // The pager's own scroll transition. An earlier version swapped the page underneath a
        // snapshot and slid the snapshot off by hand, which read like an Android activity
        // transition (the old screen slid away over a page that was already static). The
        // built-in transition is the exact same motion a finger swipe drives -- both pages move
        // together as one surface -- so bar taps and swipes feel like the same gesture.
        pager.setViewControllers(
            [pageControllers[index]],
            direction: direction,
            animated: animated,
            completion: { _ in finish() }
        )
    }

    /// Lifts the bar exactly as far as the keyboard overlaps the shell, along the keyboard's own
    /// curve, so the search pill rides the keyboard the way the overlay arrangement did.
    private func applyKeyboardFrame(_ notification: Notification) {
        guard isViewLoaded, view.window != nil else { return }
        let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero
        let frameInView = view.convert(endFrame, from: nil)
        let overlap = max(0, view.bounds.maxY - frameInView.minY)
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        barBottomConstraint.constant = -overlap
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: UIView.AnimationOptions(rawValue: curve << 16)
        ) {
            self.view.layoutIfNeeded()
        }
    }

    // MARK: - UIPageViewControllerDataSource

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard let index = pageControllers.firstIndex(where: { $0 === viewController }),
              index > 0 else { return nil }
        return pageControllers[index - 1]
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard let index = pageControllers.firstIndex(where: { $0 === viewController }),
              index + 1 < pageControllers.count else { return nil }
        return pageControllers[index + 1]
    }

    // MARK: - UIPageViewControllerDelegate

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        // Only a settled swipe writes the state; a swipe that was dragged and released back where
        // it started reports completed == false.
        guard completed,
              let visible = pageViewController.viewControllers?.first,
              let index = pageControllers.firstIndex(where: { $0 === visible }) else { return }
        currentIndex = index
        let tab: LiquidTabItem = index == 1 ? .settings : .home
        if state.selectedTab != tab { state.selectedTab = tab }
        // Mirrors Android closing the search surface once the settings page settles.
        if index == 1 && state.isSearchPresented { state.dismissSearch() }
    }
}
