import SwiftUI
import WebKit

/// iOS counterpart of `WebMaterialReader.kt`.
///
/// The shared `cupk-reader.js` adapter owns every university DOM selector. Android injects it
/// into a WebView and receives structured JSON through a JavaScript interface; this port injects
/// the same script through `WKUserScript` and receives the payload through
/// `WKScriptMessageHandler`, so both platforms render identical results.
struct MaterialReaderView: UIViewRepresentable {
    let url: String
    let adapterScript: String
    let schoolConfigJSON: String
    let refreshToken: Int
    let action: MaterialReaderAction?
    let isDark: Bool
    let onLoading: (Bool) -> Void
    let onContent: (MaterialPage) -> Void
    let onError: (String) -> Void
    let onSessionExpired: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        // The host API mirrors the Android `PalmAcademicHost` object exactly.
        let hostAPI = """
        window.PalmAcademicHost = {
          apiVersion: 1,
          schoolConfig: \(schoolConfigJSON),
          publish: function(payload) {
            window.webkit.messageHandlers.\(BridgeHandler.name).postMessage(JSON.stringify(payload));
          }
        };
        """

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        let scriptHandler = BridgeHandler(coordinator: context.coordinator)
        context.coordinator.bridgeHandler = scriptHandler

        // These have to go on `webView.configuration`, not on the `configuration` local.
        // `WKWebView` copies the configuration it was handed at init, so the original object is
        // detached from the running page afterwards. Registering on the local left the web view
        // with no `PalmAcademicBridge` message handler and no injected host object, so the adapter
        // script's very first guard -- `if (!window.PalmAcademicHost) return` -- bailed out and
        // nothing was ever published. That is the "一直加载" the page showed: no content, no error,
        // just a spinner.
        let controller = webView.configuration.userContentController
        controller.add(scriptHandler, name: BridgeHandler.name)
        controller.addUserScript(
            WKUserScript(source: hostAPI, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        // The adapter is injected at document-end rather than through `evaluateJavaScript` alone.
        // Its bootstrap calls `observer.observe(document.body, ...)`, which throws if the body does
        // not exist yet; at didCommit it often does not, and a thrown bootstrap would leave
        // `window.PalmAcademicAdapter` half-installed so no retry could recover.
        let adapter = adapterScript
        if !adapter.isEmpty {
            controller.addUserScript(
                WKUserScript(source: adapter, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
            )
        }

        context.coordinator.applyAppearance(to: webView, isDark: isDark)

        // Replay the persisted session cookie before the first navigation, mirroring
        // `PortalSessionStore.restoreToWebView`. The completion runs after the WebView's own
        // cookie store has been populated; loading before then bounces off a login redirect.
        if let target = URL(string: url) {
            let request = URLRequest(url: target)
            SessionStore.shared.restoreToWebView { [weak webView] in
                webView?.load(request)
            }
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyAppearance(to: webView, isDark: isDark)
        if context.coordinator.refreshToken != refreshToken {
            context.coordinator.refreshToken = refreshToken
            webView.reload()
        }
        if let action, context.coordinator.actionToken != action.token {
            context.coordinator.actionToken = action.token
            perform(action, in: webView)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: BridgeHandler.name)
        webView.stopLoading()
    }

    private func perform(_ action: MaterialReaderAction, in webView: WKWebView) {
        let encodedID = MaterialReaderView.javaScriptString(action.id)
        let encodedValue = MaterialReaderView.javaScriptString(action.value)
        let script = "window.PalmAcademicAdapter && window.PalmAcademicAdapter.perform(\(encodedID),\(encodedValue));"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private static func javaScriptString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String],
              array.count == 1 else { return "\"\"" }
        return array[0]
    }

    final class BridgeHandler: NSObject, WKScriptMessageHandler {
        static let name = "PalmAcademicBridge"
        weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let json = message.body as? String,
                  let page = MaterialPageParser.parse(json) else { return }
            guard let url = message.webView?.url?.absoluteString else {
                coordinator?.parent.onContent(page)
                return
            }
            MaterialPageCache.save(url: url, json: json)
            coordinator?.parent.onContent(page)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MaterialReaderView
        var refreshToken: Int
        var actionToken: Int
        weak var bridgeHandler: BridgeHandler?

        init(parent: MaterialReaderView) {
            self.parent = parent
            self.refreshToken = parent.refreshToken
            self.actionToken = parent.action?.token ?? -1
        }

        func applyAppearance(to webView: WKWebView, isDark: Bool) {
            // Mirrors `configurePortalWebDarkening`; only a light/dark document style is applied so
            // the adapter keeps reading the same DOM.
            webView.overrideUserInterfaceStyle = isDark ? .dark : .light
        }

        private func injectReader(_ webView: WKWebView) {
            let adapter = parent.adapterScript
            guard !adapter.isEmpty else { return }
            // Re-inject only when the adapter is genuinely absent. The guard at the top of the
            // script makes a second run a no-op, but running it on every commit still costs a
            // round trip and, more importantly, would re-run against a page whose adapter is
            // already watching -- so this asks first.
            webView.evaluateJavaScript("!!window.PalmAcademicAdapter") { [weak self] result, _ in
                guard let self else { return }
                let installed = (result as? Bool) ?? false
                guard !installed else { return }
                self.installReader(webView)
            }
        }

        /// The host object is a document-start user script, so it is normally already in place by
        /// the time this runs. It is re-declared here for the case where the page was restored from
        /// the back/forward cache and the document-start script did not fire.
        private func installReader(_ webView: WKWebView) {
            let hostAPI = """
            if (!window.PalmAcademicHost) {
              window.PalmAcademicHost = {
                apiVersion: 1,
                schoolConfig: \(parent.schoolConfigJSON),
                publish: function(payload) {
                  window.webkit.messageHandlers.\(BridgeHandler.name).postMessage(JSON.stringify(payload));
                }
              };
            }
            """
            webView.evaluateJavaScript(hostAPI) { [weak self] _, _ in
                guard let self else { return }
                webView.evaluateJavaScript(self.parent.adapterScript, completionHandler: nil)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onLoading(true)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            let currentURL = webView.url?.absoluteString ?? ""
            if AuthRepository.isLoginPage("", finalURL: currentURL) {
                parent.onLoading(false)
                parent.onSessionExpired()
                return
            }
            // Observe the DOM as soon as it is drawable instead of waiting for every subresource.
            injectReader(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let finalURL = webView.url?.absoluteString ?? ""
            if AuthRepository.isLoginPage("", finalURL: finalURL) {
                parent.onLoading(false)
                parent.onSessionExpired()
                return
            }
            // WKWebView delegate callbacks are not annotated as main-actor isolated,
            // so the hop to the session store is made explicitly.
            Task {
                await SessionStore.shared.captureFromWebView()
            }
            // Fallback for page loads that never issued a commit callback.
            injectReader(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onLoading(false)
            parent.onError(error.localizedDescription.isEmpty ? "内容加载失败" : error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            parent.onLoading(false)
            parent.onError(error.localizedDescription.isEmpty ? "内容加载失败" : error.localizedDescription)
        }

        /// Port of `WebViewClient.shouldOverrideUrlLoading` / `shouldInterceptRequest`.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if !Self.isReadOnlyRequest(navigationAction.request, url: url) {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        private static let safeReadPostMarkers = [
            "/search", "/query", "/list", "/page", "/get-data", "/find",
            "/preview", "/statistics", "/options"
        ]

        private static func isReadOnlyRequest(_ request: URLRequest, url: URL) -> Bool {
            guard url.scheme?.lowercased() == "https" else { return false }
            let method = (request.httpMethod ?? "GET").uppercased()
            if method == "GET" || method == "HEAD" { return true }
            let path = url.path.lowercased()
            return method == "POST" && safeReadPostMarkers.contains { path.contains($0) }
        }
    }
}