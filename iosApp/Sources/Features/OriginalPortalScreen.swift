import SwiftUI
import WebKit

/// iOS counterpart of `OriginalPortalActivity.kt`: the school portal's own page, untouched.
///
/// The home screen splits its items the way Android's `openItem` does -- a `quick` entry is drawn
/// by the shared JS adapter, everything else is whatever the portal serves. Only the first kind
/// has a native layout worth showing, so routing every row through `MaterialPageScreen` left the
/// rest of the portal either blank or reduced to whatever the adapter happened to publish. The
/// quick/other split is the one Android draws at `HomeActivity.openItem`.
///
/// The load itself goes through the portal's own menu rather than straight to the item URL. The
/// portal initialises its session, permissions and menu state on `/home`, and deep-linking a
/// subsection from a cold start lands on a page that has not been set up yet. Android handles this
/// by loading the home page, then clicking the matching `a.menu-item`; the script below is that
/// same approach, so both platforms enter a subsection the way the portal intends.
struct OriginalPortalScreen: View {
    @EnvironmentObject private var state: AppState
    let item: PortalItem

    @State private var phase: Phase = .loading
    @State private var message: String?
    @State private var refreshToken = 0
    /// How many times the menu script has been retried. The portal renders its menu asynchronously,
    /// so the first couple of attempts routinely land before the item exists.
    @State private var menuAttempts = 0

    /// `fileprivate` rather than `private`: the sibling `PortalWebView` below reports into it, and
    /// `private` at type scope would not be visible there.
    fileprivate enum Phase: Equatable {
        case loading
        /// The portal page is on screen. The WebView is the content, so there is nothing to draw on
        /// top -- this case exists so the spinner can be taken away.
        case ready
        case failed(String)
        case sessionExpired
    }

    private var baseURL: String {
        state.definition?.baseUrl ?? "\(SchoolCatalog.shared.origin)/student"
    }

    private var targetURL: String {
        item.url(baseURL: baseURL)
    }

    var body: some View {
        ZStack(alignment: .top) {
            PortalPalette.page.ignoresSafeArea()

            PortalWebView(
                title: item.title,
                targetURL: targetURL,
                homeURL: homeURL,
                isDark: state.isDark,
                refreshToken: refreshToken,
                onPhase: { phase = $0 },
                onOpenMenuItem: openThroughPortalMenu
            )
            .ignoresSafeArea(edges: .bottom)

            if case .loading = phase {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 6)
                    .transition(.opacity)
            }

            // A load that failed gets a page of its own rather than a transient alert: the alert
            // would be dismissed by the first tap and leave a blank WebView behind it, with nothing
            // on screen to explain why. The reload in the toolbar re-runs the whole sequence.
            if case .failed(let reason) = phase {
                failureView(reason)
                    .transition(.opacity)
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    refreshToken &+= 1
                    phase = .loading
                    message = nil
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("重新加载")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: phase)
        // The session prompt is the one alert that needs a decision, so it is asked for separately
        // from the load-failure notice rather than folded into one dialog whose buttons would change
        // meaning.
        .alert("登录状态已失效", isPresented: sessionExpiredBinding) {
            Button("重新登录", role: .destructive) { state.signOut() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("教务系统登录状态已过期或账号凭据已变更，请重新登录。")
        }
        .alert("无法打开页面", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("好", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func failureView(_ reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(PortalPalette.secondaryText)
            Text("无法打开\(item.title)")
                .font(.headline)
            Text(reason)
                .font(.footnote)
                .foregroundStyle(PortalPalette.secondaryText)
                .multilineTextAlignment(.center)
            Button("重试") {
                refreshToken &+= 1
                phase = .loading
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 2)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PortalPalette.page)
    }

    private var sessionExpiredBinding: Binding<Bool> {
        Binding(
            get: { phase == .sessionExpired },
            set: { if !$0 { phase = .loading } }
        )
    }

    /// The portal's landing page. Every ordinary subsection is reached from here, because that is
    /// the page that establishes the session the subsections depend on.
    ///
    /// The school file declares its own `auth.homePath`; `SchoolDefinition` does not decode that
    /// block, so the path the portal uses is the one its own config fixes -- the same `/home` the
    /// Android `PortalConfig.HOME` points at.
    private var homeURL: String {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return base + "/home"
    }

    /// Port of `OriginalPortalActivity.openThroughPortalMenu`.
    ///
    /// The menu is matched by visible label first and by resolved path second, because the portal
    /// renames menu entries between terms but keeps the hrefs stable. `browsertab` is forced off so
    /// the result stays in this WebView rather than handing off to Safari, and the tap is dispatched
    /// as a real DOM click so the portal's own handler runs -- synthesising a navigation would skip
    /// the initialisation it performs.
    private func openThroughPortalMenu(_ evaluate: @escaping (String, @escaping (Bool) -> Void) -> Void) {
        let script = """
        (function() {
          var title = \(javaScriptString(item.title));
          var target = \(javaScriptString(targetURL));
          var targetPath;
          try { targetPath = new URL(target).pathname; } catch (_) { return false; }
          var normalize = function(value) { return (value || '').replace(/\\s+/g, ' ').trim(); };
          var menuItems = Array.from(document.querySelectorAll('a.menu-item'));
          var candidate = menuItems.find(function(node) {
            return normalize(node.getAttribute('data-text') || node.textContent) === title;
          });
          if (!candidate) candidate = menuItems.find(function(node) {
            var href = node.getAttribute('href') || '';
            try { return href && new URL(href, location.href).pathname === targetPath; } catch (_) { return false; }
          });
          if (!candidate) return false;

          candidate.setAttribute('browsertab', 'false');
          candidate.removeAttribute('target');

          var menuToggle = Array.from(document.querySelectorAll('button,a')).find(function(node) {
            return normalize(node.getAttribute('data-text') || node.textContent).indexOf('菜单') >= 0;
          });
          if (menuToggle && !menuToggle.classList.contains('active')) menuToggle.click();
          setTimeout(function() { candidate.click(); }, 80);
          return true;
        })();
        """
        evaluate(script) { [weak self] matched in
            guard let self else { return }
            if matched { return }
            if self.menuAttempts < 3 {
                self.menuAttempts += 1
                let delay = self.menuAttempts == 1 ? 0.3 : 0.65
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.openThroughPortalMenu(evaluate)
                }
            } else {
                // Android leaves the user on the portal home page with a toast rather than a dead
                // screen, and the toolbar still offers a reload, so this is recoverable in place.
                self.message = "未在教务菜单中找到“\(self.item.title)”，已停留在教务首页，可点击右上角重新加载。"
            }
        }
    }

    private func javaScriptString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String],
              array.count == 1 else { return "\"\"" }
        return array[0]
    }
}

/// The plain portal surface: a `WKWebView` with the app's session cookies and no adapter.
///
/// Deliberately not `MaterialReaderView` with an empty script. That view hides itself at 1% opacity
/// and exists only to pump JSON out of the portal's DOM; here the page is the content, so it is
/// shown at full size and given hit testing.
private struct PortalWebView: UIViewRepresentable {
    let title: String
    let targetURL: String
    let homeURL: String
    let isDark: Bool
    let refreshToken: Int
    let onPhase: (OriginalPortalScreen.Phase) -> Void
    let onOpenMenuItem: (@escaping (String, @escaping (Bool) -> Void) -> Void) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // The portal sets its own viewport; forcing a fixed native width would squash it.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.applyAppearance(to: webView, isDark: isDark)
        context.coordinator.load(webView, homeURL: homeURL, targetURL: targetURL)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyAppearance(to: webView, isDark: isDark)
        if context.coordinator.loadedRefreshToken != refreshToken {
            context.coordinator.loadedRefreshToken = refreshToken
            context.coordinator.load(webView, homeURL: homeURL, targetURL: targetURL)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: PortalWebView
        var loadedRefreshToken = 0
        /// Set once the menu has successfully driven the navigation. Without it every later page
        /// finish -- including the portal navigating on its own afterwards -- would look like the
        /// home page again and start the menu search over, yanking the user back.
        private var menuNavigationStarted = false

        init(parent: PortalWebView) {
            self.parent = parent
        }

        func load(_ webView: WKWebView, homeURL: String, targetURL: String) {
            menuNavigationStarted = false
            // Restore the persisted session before the first navigation, mirroring
            // `PortalSessionStore.restoreToWebView`: loading before the cookie store is populated
            // bounces off a login redirect.
            SessionStore.shared.restoreToWebView { [weak webView] in
                guard let url = URL(string: homeURL) else { return }
                webView?.load(URLRequest(url: url))
            }
        }

        func applyAppearance(to webView: WKWebView, isDark: Bool) {
            let background = isDark ? UIColor.black : UIColor.systemBackground
            webView.backgroundColor = background
            webView.scrollView.backgroundColor = background
            webView.isOpaque = true
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // A bounce to the login page means the stored session is no longer good.
            if webView.url?.path.hasSuffix("/login") == true {
                parent.onPhase(.sessionExpired)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            if url.path.hasSuffix("/login") {
                parent.onPhase(.sessionExpired)
                return
            }
            // The item is on screen, or the portal moved somewhere on its own. Either way the menu
            // search is over and the spinner has nothing left to wait for.
            guard !menuNavigationStarted else {
                parent.onPhase(.ready)
                return
            }
            // Only drive the menu when the portal is actually sitting on its home page; otherwise
            // the item is already open and clicking a menu entry would navigate away from it.
            guard url.absoluteString == parent.homeURL || url.path == URL(string: parent.homeURL)?.path else {
                parent.onPhase(.ready)
                return
            }
            parent.onOpenMenuItem { [weak self] script, completion in
                webView.evaluateJavaScript(script) { [weak self] value, _ in
                    if (value as? Bool) == true { self?.menuNavigationStarted = true }
                    completion((value as? Bool) == true)
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onPhase(.failed(error.localizedDescription))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.onPhase(.failed(error.localizedDescription))
        }
    }
}
