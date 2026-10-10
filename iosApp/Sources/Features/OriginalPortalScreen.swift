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
/// Imported definitions already declare the exact URL for every non-redrawn item. The WebView
/// therefore restores the shared cookies and loads that URL directly, just like a normal browser.
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
        VStack(spacing: 0) {
            // The app chrome owns an opaque, adaptive surface including the top safe area. The
            // WebView is a separate layout region below it, so portal content can never slide
            // underneath the back/title/refresh controls.
            topChrome
                .background(PortalPalette.plainSurface.ignoresSafeArea(edges: .top))

            ZStack {
                PortalWebView(
                    targetURL: targetURL,
                    isDark: state.isDark,
                    refreshToken: refreshToken,
                    onPhase: { newPhase in
                        if newPhase == .sessionExpired && state.captchaRequired && state.definition?.auth?.isWebOnly != true {
                            state.requireCaptchaReauthentication()
                            dismiss()
                        } else if newPhase == .sessionExpired && state.supportsSilentPasswordReauthentication {
                            phase = .loading
                            Task { @MainActor in
                                let restored = await state.revalidateQuietlyPublic()
                                if restored {
                                    refreshToken += 1
                                } else {
                                    phase = .sessionExpired
                                }
                            }
                        } else {
                            phase = newPhase
                        }
                    }
                )

                // A load that failed gets a page of its own rather than a transient alert: the
                // alert would be dismissed by the first tap and leave a blank WebView behind it.
                if case .failed(let reason) = phase {
                    failureView(reason)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PortalPalette.plainSurface.ignoresSafeArea())
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

            ProgressView()
                .progressViewStyle(.linear)
                .frame(height: 3)
                .padding(.horizontal, 14)
                .opacity(phase == .loading ? 1 : 0)
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

}

/// The plain portal surface: a `WKWebView` with the app's session cookies and no adapter.
///
/// Deliberately not `MaterialReaderView` with an empty script. That view hides itself at 1% opacity
/// and exists only to pump JSON out of the portal's DOM; here the page is the content, so it is
/// shown at full size and given hit testing.
private struct PortalWebView: UIViewRepresentable {
    let targetURL: String
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
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // SwiftUI lays this WebView below the app-owned header and inside the bottom safe area.
        // Disabling UIKit's automatic adjustment avoids applying a second top inset.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.applyAppearance(to: webView, isDark: isDark)
        context.coordinator.load(webView, targetURL: targetURL)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyAppearance(to: webView, isDark: isDark)
        if context.coordinator.loadedRefreshToken != refreshToken {
            context.coordinator.loadedRefreshToken = refreshToken
            context.coordinator.load(webView, targetURL: targetURL)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: PortalWebView
        var loadedRefreshToken = 0

        init(parent: PortalWebView) {
            self.parent = parent
        }

        @MainActor
        func load(_ webView: WKWebView, targetURL: String) {
            guard let url = URL(string: targetURL) else {
                parent.onPhase(.failed("页面地址无效"))
                return
            }
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            // With a saved session, wait until every cookie has entered WebKit. When there is no
            // persisted cookie, restoreToWebView returns false and never invokes its completion;
            // the old implementation ignored that return value and consequently never navigated.
            let restored = SessionStore.shared.restoreToWebView { [weak webView] in
                webView?.load(request)
            }
            if !restored { webView.load(request) }
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
            Task { @MainActor in
                await SessionStore.shared.captureFromWebView()
            }
            parent.onPhase(.ready)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if let upgraded = upgradedPortalURL(url) {
                decisionHandler(.cancel)
                webView.load(URLRequest(url: upgraded, cachePolicy: .reloadIgnoringLocalCacheData))
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard !isBenignNavigationInterruption(error) else { return }
            parent.onPhase(.failed(error.localizedDescription))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard !isBenignNavigationInterruption(error) else { return }
            parent.onPhase(.failed(error.localizedDescription))
        }

        private func isBenignNavigationInterruption(_ error: Error) -> Bool {
            let value = error as NSError
            return value.code == NSURLErrorCancelled ||
                (value.domain == WKError.errorDomain &&
                    value.code == 102) // frameLoadInterruptedByPolicyChange (not exposed by older SDKs)
        }

        private func upgradedPortalURL(_ url: URL) -> URL? {
            guard url.scheme?.lowercased() == "http",
                  let requestedHost = url.host?.lowercased(),
                  requestedHost == URL(string: parent.targetURL)?.host?.lowercased(),
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return nil }
            components.scheme = "https"
            return components.url
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil,
               let requested = navigationAction.request.url {
                if let upgraded = upgradedPortalURL(requested) {
                    webView.load(URLRequest(url: upgraded))
                } else if requested.scheme?.lowercased() == "https" {
                    webView.load(navigationAction.request)
                }
            }
            return nil
        }

    }
}
