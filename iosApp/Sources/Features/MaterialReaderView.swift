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

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        let scriptHandler = BridgeHandler(coordinator: context.coordinator)
        context.coordinator.bridgeHandler = scriptHandler
        configuration.userContentController.add(scriptHandler, name: BridgeHandler.name)

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
        let userScript = WKUserScript(
            source: hostAPI,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(userScript)
        webView.configuration.userContentController.addUserScript(
            WKUserScript(source: "", injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        // Replay the persisted session cookie before the first navigation, mirroring
        // `PortalSessionStore.restoreToWebView`.
        SessionStore.shared.restoreToCookieStorage()
        context.coordinator.applyAppearance(to: webView, isDark: isDark)
        if let target = URL(string: url) {
            webView.load(URLRequest(url: target))
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
            webView.evaluateJavaScript(adapter, completionHandler: nil)
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
            Task { @MainActor in
                SessionStore.shared.captureFromWebView()
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