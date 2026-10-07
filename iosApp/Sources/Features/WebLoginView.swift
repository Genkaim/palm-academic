import SwiftUI
import WebKit

/// iOS counterpart of `WebLoginActivity.kt`.
///
/// The password form in `LoginView` posts straight to the salt/login handshake, which some
/// deployments answer with a captcha challenge that only a real browser engine can clear.
/// This screen runs that handshake inside a `WKWebView`, and when the portal stops serving
/// the login page the cookie it produced is captured into `SessionStore` — after which the
/// normal `URLSession` path is authenticated and the app can leave the web view behind.
struct WebLoginView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var progress: Double = 0
    @State private var statusMessage: String?
    @State private var didFinish = false

    /// The portal serves the login form here; the Android activity loads the same path.
    private var loginURL: String {
        let origin = SchoolCatalog.shared.origin
        return "\(origin)/student/login"
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            // A thin determinate bar mirrors `WebLoginActivity`'s progress bar, so a slow
            // portal still reads as "working" rather than "stuck".
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(height: 3)
                .opacity(progress < 1 ? 1 : 0)

            WebLoginWebView(
                url: loginURL,
                isDark: state.isDark,
                onProgress: { progress = $0 },
                onAuthenticated: {
                    didFinish = true
                    Task { @MainActor in
                        await adoptWebSession()
                        dismiss()
                    }
                },
                onFailure: { statusMessage = $0 }
            )
            .ignoresSafeArea(edges: .bottom)

            if let statusMessage {
                Text(statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(Color(red: 0.75, green: 0.15, blue: 0.15))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(state.isDark ? 0.35 : 0.06))
            }
        }
        .background(state.isDark ? Color(red: 0.06, green: 0.07, blue: 0.09) : Color.white)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
            }
            .accessibilityLabel("返回")

            VStack(alignment: .leading, spacing: 1) {
                Text("网页登录")
                    .font(.body.weight(.semibold))
                if let host = URL(string: SchoolCatalog.shared.origin)?.host {
                    Text(host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if didFinish {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(
            state.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
        )
    }

    /// Leaving the web view is only safe once the captured cookie actually authenticates the
    /// programmatic session. The portal can render a page that looks signed in while still
    /// withholding SESSION, so the cookie is validated before the app commits to `.signedIn`.
    private func adoptWebSession() async {
        let auth = AuthRepository()
        switch await auth.validateSession() {
        case .valid:
            state.completeWebLogin()
        case .expired, .unavailable:
            state.dismissWebLogin(message: "网页登录未完成，请重试")
        }
    }
}

/// The browser surface itself. Split out so the SwiftUI chrome above can rebind freely
/// without tearing the web view down on every state change.
private struct WebLoginWebView: UIViewRepresentable {
    let url: String
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
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

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
    /// main-actor state is made explicitly — the same shape `MaterialReaderView` uses.
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
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onProgress(1)
            guard !didAuthenticate else { return }

            // WKWebView has no synchronous DOM accessor, so the page markup is read back through
            // JavaScript before deciding whether the login form is still what is on screen.
            // The URL alone is not enough: the portal often stays on /student/login while
            // swapping the form for an authenticated shell.
            let url = webView.url?.absoluteString ?? ""
            webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
                guard let self else { return }
                let html = result as? String ?? ""
                Task { @MainActor in
                    guard !self.didAuthenticate else { return }
                    guard !AuthRepository.isLoginPage(html, finalURL: url) else {
                        // Still the login form: the user has to finish typing there.
                        return
                    }
                    // Past the login form, so its cookies are the session now.
                    SessionStore.shared.captureFromWebView()
                    self.didAuthenticate = true
                    self.parent.onProgress(1)
                    self.parent.onAuthenticated()
                }
            }
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