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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: PortalItem

    @State private var phase: Phase = .loading
    @State private var refreshToken = 0

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
            // Match the web view's OWN opaque background rather than the grouped page colour:
            // the surface here is the portal document (white/black), and painting the grouped
            // grey behind the status bar left a visible seam -- a solid colour block -- between
            // the transparent nav bar and the page.
            PortalPalette.plainSurface.ignoresSafeArea()

            PortalWebView(
                title: item.title,
                targetURL: targetURL,
                homeURL: homeURL,
                menuScript: makeMenuScript(),
                isDark: state.isDark,
                refreshToken: refreshToken,
                onPhase: { phase = $0 }
            )
            // Full bleed on every edge: the document background paints under the status bar and
            // behind the home indicator. The scroll view's own inset adjustment keeps the page
            // CONTENT clear of the bars, so nothing is hidden -- only the dead strip is gone.
            .ignoresSafeArea()

            // A load that failed gets a page of its own rather than a transient alert: the alert
            // would be dismissed by the first tap and leave a blank WebView behind it, with nothing
            // on screen to explain why. The reload in the toolbar re-runs the whole sequence.
            if case .failed(let reason) = phase {
                failureView(reason)
                    .transition(.opacity)
            }

            // Non-redrawn pages use the same floating glass chrome as web login: a round back
            // control, a compact title capsule, and an independent refresh control at top-right.
            topChrome
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(false)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: phase)
        // The session prompt is the one alert that needs a decision, so it is asked for separately
        // from the menu-miss notice rather than folded into one dialog whose buttons would change
        // meaning.
        .alert("登录状态已失效", isPresented: sessionExpiredBinding) {
            Button("重新登录", role: .destructive) { state.signOut() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("教务系统登录状态已过期或账号凭据已变更，请重新登录。")
        }
    }

    private var topChrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SystemGlassSurface(shape: Circle(), interactive: true) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(PortalPalette.onSurface)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(TabPressStyle())
                }
                .frame(width: 44, height: 44)
                .accessibilityLabel("返回")

                SystemGlassSurface(shape: Capsule(style: .continuous), interactive: false) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PortalPalette.onSurface)
                            .lineLimit(1)
                        if let host = URL(string: targetURL)?.host {
                            Text(host)
                                .font(.caption2)
                                .foregroundStyle(PortalPalette.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                }
                .frame(height: 44)

                Spacer(minLength: 0)

                SystemGlassSurface(shape: Circle(), interactive: true) {
                    Button {
                        refreshToken &+= 1
                        phase = .loading
                    } label: {
                        Group {
                            if case .loading = phase {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(PortalPalette.onSurface)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                    }
                    .buttonStyle(TabPressStyle())
                }
                .frame(width: 44, height: 44)
                .accessibilityLabel("重新加载")
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 8)

            if case .loading = phase {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(height: 3)
                    .padding(.horizontal, 14)
            }
        }
        .background(
            LinearGradient(
                colors: [
                    PortalPalette.plainSurface.opacity(0.82),
                    PortalPalette.plainSurface.opacity(0.55),
                    PortalPalette.plainSurface.opacity(0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 132)
            .ignoresSafeArea(edges: .top),
            alignment: .top
        )
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
        .background(PortalPalette.plainSurface.ignoresSafeArea())
    }

    private var sessionExpiredBinding: Binding<Bool> {
        Binding(
            get: { phase == .sessionExpired },
            // Dismissing the prompt does not resume a load that is not going to succeed: the stored
            // session is gone, so the page is left as it is until the user re-logs in or reloads.
            set: { if !$0 { phase = .ready } }
        )
    }

    /// The portal's landing page. It is loaded first purely to establish the session: the portal
    /// only issues its session cookies once it has run its own bootstrap on this page, and a cold
    /// request straight to a subsection is bounced back to the login form.
    ///
    /// The school file declares an `auth.homePath`, but `SchoolDefinition` does not decode that
    /// block, so the path is the one the portal itself uses -- the same `/home` Android's
    /// `PortalConfig.HOME` points at.
    private var homeURL: String {
        if let configured = state.definition?.auth?.homePath,
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if configured.hasPrefix("http://") || configured.hasPrefix("https://") {
                return configured
            }
            let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
            return base + (configured.hasPrefix("/") ? configured : "/\(configured)")
        }
        if let success = state.definition?.auth?.resolvedSuccessPrefixes.first,
           !success.isEmpty {
            return success
        }
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return base + "/home"
    }

    /// Opens the portal menu entry for this item, if the portal has one that can be recognised.
    ///
    /// This is a best-effort nicety, not the navigation mechanism, and it is written the way the
    /// portal's own menu is more likely to be marked up: every anchor that looks like a menu entry
    /// is considered, not just one hard-coded class. Android's `OriginalPortalActivity` looks only
    /// for `a.menu-item`, which is a guess about the portal's markup that was never verified -- and
    /// matching on a class nothing renders is why the screen used to report "未在教务菜单中找到"
    /// for items that were sitting right there in the menu.
    ///
    /// `browsertab` is forced off so the result stays in this WebView, and the tap is dispatched as
    /// a real DOM click so the portal's own handler runs rather than a synthesised navigation.
    private func makeMenuScript() -> String {
        """
        (function() {
          var title = \(javaScriptString(item.title));
          var target = \(javaScriptString(targetURL));
          var targetPath;
          try { targetPath = new URL(target).pathname; } catch (_) { return false; }
          var normalize = function(value) { return (value || '').replace(/\\s+/g, ' ').trim(); };
          var label = function(node) {
            return normalize(node.getAttribute('data-text') || node.getAttribute('title') || node.textContent);
          };
          // Any anchor inside the page's own navigation area, not one specific class. A portal that
          // renames its menu should still be reachable.
          var links = Array.from(document.querySelectorAll('a[href]'));
          var inMenu = function(node) {
            var closest = node.closest('nav, .menu, .sidebar, [class*="menu"], [class*="nav"], [role="navigation"]');
            return !!closest;
          };
          var candidates = links.filter(function(node) {
            return inMenu(node) || /menu|nav/i.test(node.className || '');
          });
          if (candidates.length === 0) candidates = links;

          var candidate = candidates.find(function(node) { return label(node) === title; });
          if (!candidate) candidate = candidates.find(function(node) {
            var href = node.getAttribute('href') || '';
            try { return href && new URL(href, location.href).pathname === targetPath; } catch (_) { return false; }
          });
          // Last resort: the href alone. Titles drift between terms, paths do not.
          if (!candidate) candidate = links.find(function(node) {
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
    let menuScript: String
    let isDark: Bool
    let refreshToken: Int
    let onPhase: (OriginalPortalScreen.Phase) -> Void

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
        // The view is laid out edge to edge, and this lets the scroll view inset the document's
        // CONTENT for the status bar / nav bar itself while its background still paints under
        // them (the immersive effect). `.never` left the page's top row hidden under the bar.
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        context.coordinator.applyAppearance(to: webView, isDark: isDark)
        context.coordinator.load(webView, homeURL: homeURL)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyAppearance(to: webView, isDark: isDark)
        if context.coordinator.loadedRefreshToken != refreshToken {
            context.coordinator.loadedRefreshToken = refreshToken
            context.coordinator.load(webView, homeURL: homeURL)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// The portal builds its menu asynchronously, so the first attempts routinely land before
        /// the item exists. Android retries three times on the same escalating delay.
        private static let maximumMenuAttempts = 3

        var parent: PortalWebView
        var loadedRefreshToken = 0
        /// Set once the menu has successfully driven the navigation. Without it every later page
        /// finish -- including the portal navigating on its own afterwards -- would look like the
        /// home page again and start the menu search over, yanking the user back.
        private var menuNavigationStarted = false
        private var menuAttempts = 0
        private var retryWork: DispatchWorkItem?
        /// The URL the session was established on. Navigation away from it is what triggers the
        /// menu search, and it is tracked by URL rather than by a flag because the portal may
        /// redirect `/home` to an equivalent URL with a different query.
        private var sessionURL: String = ""

        init(parent: PortalWebView) {
            self.parent = parent
        }

        @MainActor
        func load(_ webView: WKWebView, homeURL: String) {
            retryWork?.cancel()
            retryWork = nil
            menuNavigationStarted = false
            menuAttempts = 0
            sessionURL = ""
            // Restore the persisted session before the first navigation, mirroring
            // `PortalSessionStore.restoreToWebView`: loading before the cookie store is populated
            // bounces off a login redirect.
            SessionStore.shared.restoreToWebView { [weak self, weak webView] in
                guard let url = URL(string: homeURL) else { return }
                self?.sessionURL = homeURL
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
            // The item is on screen, or the portal moved somewhere on its own. Either way there is
            // nothing left to open and the spinner has nothing to wait for.
            guard !menuNavigationStarted else {
                parent.onPhase(.ready)
                return
            }
            // Only look for a menu entry while the portal is still on the page that established the
            // session. Anywhere else the item is already open, and clicking a menu entry would
            // navigate away from it.
            let isSessionPage = sessionURL.isEmpty
                || url.absoluteString == sessionURL
                || url.path == URL(string: sessionURL)?.path
            guard isSessionPage else {
                parent.onPhase(.ready)
                return
            }
            attemptMenu(in: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            retryWork?.cancel()
            parent.onPhase(.failed(error.localizedDescription))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            retryWork?.cancel()
            parent.onPhase(.failed(error.localizedDescription))
        }

        private func attemptMenu(in webView: WKWebView) {
            webView.evaluateJavaScript(parent.menuScript) { [weak self] value, _ in
                guard let self else { return }
                if (value as? Bool) == true {
                    self.menuNavigationStarted = true
                    return
                }
                // The portal may still be rendering its menu, so retry on the same escalating
                // delay as Android. Never replace this with a direct URL load: the requested
                // behaviour is the portal's own native menu click, because its click handler owns
                // the page shell, permission setup and route initialisation.
                guard self.menuAttempts < Self.maximumMenuAttempts else {
                    // Match Android: leave the untouched portal home visible when no menu node can
                    // be matched. A direct deep link here would be precisely the path this screen
                    // exists to avoid.
                    self.parent.onPhase(.ready)
                    return
                }
                self.menuAttempts += 1
                let delay = self.menuAttempts == 1 ? 0.3 : 0.65
                let work = DispatchWorkItem { [weak self, weak webView] in
                    guard let self, let webView else { return }
                    self.retryWork = nil
                    self.attemptMenu(in: webView)
                }
                self.retryWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }
}
