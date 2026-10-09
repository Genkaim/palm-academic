import SwiftUI
import WebKit

/// iOS counterpart of `WebLoginActivity.kt`.
///
/// The password form in `LoginView` posts straight to the salt/login handshake, which some
/// deployments answer with a captcha challenge that only a real browser engine can clear.
/// This screen runs that handshake inside a `WKWebView`, and when the portal takes the browser
/// to the authenticated landing (`/student/home`, exactly what Android watches for) the cookie
/// it produced is captured into `SessionStore` -- after which the normal path is authenticated
/// and the app leaves the web view behind.
///
/// The chrome floats over a full-bleed web page: the back control and the title are liquid-glass
/// capsules with a short gradient scrim behind them, so the status-bar area and the page bottom
/// show the web page itself instead of solid toolbars.
struct WebLoginView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var progress: Double = 0
    @State private var statusMessage: String?
    @State private var didFinish = false

    /// The portal serves the login form here; the Android activity loads the same path.
    private var loginURL: String {
        if let configured = state.definition?.auth?.loginUrl, !configured.isEmpty {
            return configured
        }
        let origin = SchoolCatalog.shared.origin
        return "\(origin)/student/login"
    }

    private var authenticatedURLPrefixes: [String] {
        state.definition?.auth?.resolvedSuccessPrefixes ?? []
    }

    /// Authenticated landings. Arriving at either one is the success signal -- Android keys off
    /// `/student/home` alone, `/index` is the equivalent shell some deployments redirect to.
    private var authenticatedPaths: [String] {
        ["/student/home", "/student/index"]
    }

    var body: some View {
        ZStack(alignment: .top) {
            PortalPalette.plainSurface.ignoresSafeArea()

            WebLoginWebView(
                url: loginURL,
                authenticatedURLPrefixes: authenticatedURLPrefixes,
                authenticatedPaths: authenticatedPaths,
                isDark: state.isDark,
                onProgress: { progress = $0 },
                onAuthenticated: {
                    Task { @MainActor in
                        await adoptWebSession()
                    }
                },
                onFailure: { statusMessage = $0 }
            )
            .ignoresSafeArea()

            topChrome

            if let statusMessage {
                errorCapsule(statusMessage)
            }
        }
        .statusBarHidden(false)
    }

    // MARK: - Chrome

    private var topChrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                backButton

                titleCapsule

                Spacer(minLength: 0)

                if didFinish {
                    SystemGlassSurface(shape: Circle(), interactive: false) {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 44, height: 44)
                    }
                    .frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 8)

            // A thin determinate bar mirrors `WebLoginActivity`'s progress bar, so a slow portal
            // still reads as "working" rather than "stuck".
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(height: 3)
                .padding(.horizontal, 14)
                .opacity(progress < 1 ? 1 : 0)
        }
        // The scrim only darkens the top strip for legibility; everything below it is the web
        // page, edge to edge, including under the status bar and behind the home indicator.
        .background(
            LinearGradient(
                colors: [
                    PortalPalette.plainSurface.opacity(0.82),
                    PortalPalette.plainSurface.opacity(0.55),
                    PortalPalette.plainSurface.opacity(0.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 132)
            .ignoresSafeArea(edges: .top),
            alignment: .top
        )
    }

    /// The back control the brief calls out: a floating liquid-glass circle over the web page,
    /// mirroring Android's navigation icon but without an opaque toolbar behind it.
    private var backButton: some View {
        SystemGlassSurface(shape: Circle(), interactive: true) {
            Button {
                dismiss()
            } label: {
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
    }

    private var titleCapsule: some View {
        SystemGlassSurface(shape: Capsule(style: .continuous), interactive: false) {
            VStack(alignment: .leading, spacing: 1) {
                Text("网页登录")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PortalPalette.onSurface)
                if let host = URL(string: SchoolCatalog.shared.origin)?.host {
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
    }

    private func errorCapsule(_ message: String) -> some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.footnote)
                Text(message)
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(PortalPalette.error)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                SystemGlassSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: false) {
                    PortalPalette.errorContainer
                }
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
        }
        .allowsHitTesting(false)
    }

    /// Adopt the session the web view just established.
    ///
    /// The browser reaching the authenticated landing IS the success proof -- matching Android,
    /// which captures the cookie and finishes immediately. There is deliberately NO second
    /// programmatic validation probe here: the earlier build added one and reported "网页登录
    /// 未完成" every time the campus network was merely slow to answer the probe, even though
    /// the login itself had succeeded. Only a genuinely missing SESSION cookie is a failure.
    private func adoptWebSession() async {
        didFinish = true
        let captured = await SessionStore.shared.captureFromWebView(
            cookieHosts: state.definition?.auth?.resolvedCookieHosts,
            acceptedCookieNames: state.definition?.auth?.resolvedCookieNames
        )
        guard captured else {
            didFinish = false
            statusMessage = "未获取到登录会话，请在网页中完成登录后重试"
            return
        }
        state.completeWebLogin()
        dismiss()
    }
}

/// The browser surface itself. Split out so the SwiftUI chrome above can rebind freely
/// without tearing the web view down on every state change.
private struct WebLoginWebView: UIViewRepresentable {
    let url: String
    let authenticatedURLPrefixes: [String]
    let authenticatedPaths: [String]
    let isDark: Bool
    let onProgress: (Double) -> Void
    let onAuthenticated: () -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The portal login page ships JavaScript, so scripting cannot be turned off.
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // The page paints its own background edge to edge; with the chrome floating, a clear
        // web view would let the gradient scrim smear over the whole page during loads.
        webView.isOpaque = true
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        // Web content stays below the status bar while the page background paints under it --
        // the iOS counterpart of Android's edge-to-edge surface + inset toolbar.
        webView.scrollView.contentInsetAdjustmentBehavior = .always

        // A stale SESSION leaves the login page parked on an empty state, which mirrors the
        // Android activity's decision to start from a clean slate.
        webView.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) { }
        context.coordinator.applyAppearance(to: webView, isDark: isDark)

        if let target = URL(string: url) {
            var request = URLRequest(url: target)
            request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            webView.load(request)
        } else {
            onFailure("登录地址无效")
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyAppearance(to: webView, isDark: isDark)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    /// The delegate is left nonisolated to satisfy `WKNavigationDelegate`, and every hop into
    /// main-actor state is made explicitly -- the same shape `MaterialReaderView` uses.
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebLoginWebView
        /// Set once the session is captured so a redirect chain cannot fire it repeatedly.
        private var didAuthenticate = false
        private var didFail = false
        private var observation: NSKeyValueObservation?

        init(parent: WebLoginWebView) {
            self.parent = parent
        }

        deinit { observation?.invalidate() }

        func applyAppearance(to webView: WKWebView, isDark: Bool) {
            guard observation == nil else { return }
            observation = webView.observe(\.estimatedProgress, options: [.new]) { view, _ in
                let value = min(max(view.estimatedProgress, 0), 1)
                DispatchQueue.main.async {
                    self.parent.onProgress(value)
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in self.didFail = false }
            parent.onProgress(0.05)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.onProgress(max(webView.estimatedProgress, 0.1))
            // Reaching the authenticated landing via a client-side redirect sometimes only
            // produces a commit (the finish callback can be swallowed by the next push), so
            // check here as well as on finish.
            authenticateIfLanded(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onProgress(1)
            guard !didAuthenticate else { return }
            authenticateIfLanded(webView)
        }

        /// Decides whether the current document is the authenticated shell.
        ///
        /// Primary signal (Android parity): the URL path is one of the authenticated landings.
        /// Secondary signal for portals that land elsewhere inside the SPA: same-origin path
        /// under `/student/` whose markup is the Vue app shell WITHOUT the login markers. The
        /// URL alone is not trustworthy -- the portal can keep `/student/login` while swapping
        /// the document -- and the markup alone is not either, hence both.
        private func authenticateIfLanded(_ webView: WKWebView) {
            let urlString = webView.url?.absoluteString ?? ""
            let path = Self.normalizedPath(urlString)

            if parent.authenticatedURLPrefixes.contains(where: urlString.hasPrefix) {
                finishAuthentication()
                return
            }
            if parent.authenticatedPaths.contains(path) {
                finishAuthentication()
                return
            }
            guard !path.hasSuffix("/login") else { return }
            guard path.hasPrefix("/student/") else { return }

            webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
                guard let self else { return }
                let html = result as? String ?? ""
                Task { @MainActor in
                    guard !self.didAuthenticate else { return }
                    guard !AuthRepository.isLoginPage(html, finalURL: urlString) else { return }
                    // A non-login page still has to actually BE the authenticated app shell
                    // rather than a public help/error page served from the same path prefix.
                    let looksLikeShell = html.contains("vue_main")
                        || html.contains("logout")
                        || html.contains("退出登录")
                        || html.contains("安全退出")
                    guard looksLikeShell else { return }
                    self.finishAuthentication()
                }
            }
        }

        private func finishAuthentication() {
            guard !didAuthenticate else { return }
            didAuthenticate = true
            parent.onProgress(1)
            parent.onAuthenticated()
        }

        private static func normalizedPath(_ urlString: String) -> String {
            guard var path = URL(string: urlString)?.path else { return "" }
            while path.hasSuffix("/") && path != "/" { path.removeLast() }
            return path
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        private func report(_ error: Error) {
            let nsError = error as NSError
            // A cancelled navigation is what a redirect looks like, not a real failure.
            guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
            let message = "网页登录加载失败：\(error.localizedDescription)"
            Task { @MainActor in
                guard !self.didFail else { return }
                self.didFail = true
                self.parent.onFailure(message)
            }
        }
    }
}
