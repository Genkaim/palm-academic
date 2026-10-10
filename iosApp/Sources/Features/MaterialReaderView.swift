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
    /// The quick-entry kind ("schedule"/"grade"/"exam"/"program"), used to tell a populated
    /// publication from the page's empty DOM skeleton. Empty/placeholder publications are neither
    /// rendered nor cached, which is what keeps a refresh from wiping the data already on screen.
    let nativeType: String?
    let refreshToken: Int
    let action: MaterialReaderAction?
    let isDark: Bool
    let onLoading: (Bool) -> Void
    /// Delivers both the parsed page used by SwiftUI and the adapter's original JSON used for
    /// comparison baselines. Passing the raw publication directly also lets a stable, legitimate
    /// empty page establish a baseline without polluting the visible-page cache with DOM skeletons.
    let onContent: (MaterialPage, String) -> Void
    let onError: (String) -> Void
    let onSessionExpired: () -> Void
    /// Why the page produced nothing, in the page's own words.
    ///
    /// A reader that never publishes is otherwise indistinguishable from a slow one: the native
    /// side sees a load finish and no payload, and all it can say is "still loading". Android has
    /// the same blind spot, but it also has logcat, and iOS does not get an equivalent for free.
    /// The injected bootstrap therefore reports the specific reason back through the same bridge,
    /// so the screen can say *why* instead of spinning.
    let onDiagnostic: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        // The host API mirrors the Android `PalmAcademicHost` object exactly, plus a `report`
        // channel the Android host does not need because its failure modes are visible in logcat.
        let hostAPI = """
        window.PalmAcademicHost = {
          apiVersion: 1,
          schoolConfig: \(schoolConfigJSON),
          publish: function(payload) {
            window.__portalPublished = true;
            window.webkit.messageHandlers.\(BridgeHandler.name).postMessage(JSON.stringify(payload));
          },
          report: function(reason) {
            window.webkit.messageHandlers.\(BridgeHandler.name).postMessage(JSON.stringify({portalDiagnostic: String(reason)}));
          }
        };
        """

        // The watchdog. It runs before the adapter, so by the time it fires it can tell the three
        // cases apart: the adapter never ran, the adapter threw, or the adapter ran and produced
        // nothing. Each has a different fix, and guessing between them costs a build each time.
        let watchdog = """
        (function () {
          var announced = false;
          var report = function (reason) {
            if (announced) return;
            announced = true;
            try {
              if (window.PalmAcademicHost && window.PalmAcademicHost.report) window.PalmAcademicHost.report(reason);
            } catch (_) {}
          };
          window.__portalWatchdog = report;
          setTimeout(function () {
            if (!window.PalmAcademicAdapter) {
              report('适配器脚本未安装。host=' + (window.PalmAcademicHost ? 'ok' : 'missing')
                + ' adapterLength=' + \(adapterScript.count));
            }
          }, 8000);
          setTimeout(function () {
            if (window.__portalPublished !== true) {
              report('适配器已加载但 30 秒仍未产出内容：URL=' + location.pathname
                + ' bodyLength=' + (document.body ? document.body.innerText.length : -1));
            }
          }, 30000);
        })();
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
        // The watchdog wraps the adapter so a thrown bootstrap is reported instead of silently
        // leaving `window.PalmAcademicAdapter` half-defined, which no retry can recover from.
        let guardedAdapter = """
        (function () {
          try {
        \(adapterScript.isEmpty ? "  // no adapter configured for this school" : adapterScript)
          } catch (error) {
            if (window.PalmAcademicHost && window.PalmAcademicHost.report) {
              window.PalmAcademicHost.report('适配器执行出错：' + (error && error.message ? error.message : String(error)));
            }
          }
        })();
        """
        controller.addUserScript(
            WKUserScript(source: hostAPI, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        // The watchdog runs first, then the adapter. Both are document-end: the adapter's own
        // bootstrap calls `observer.observe(document.body, ...)`, which throws if the body does not
        // exist yet, and at didCommit it often does not -- a thrown bootstrap leaves
        // `window.PalmAcademicAdapter` half-installed, so no retry could ever recover.
        //
        // MAIN FRAME ONLY. These used to be injected into every frame
        // (`forMainFrameOnly: false`): an auxiliary same-origin iframe (announcement/help widgets
        // on the grade and exam entries) then got its OWN adapter instance, and on pages whose
        // path it did not recognise the adapter fell back to publishing the frame's whole body as
        // the page content. That payload overrode the real data through this same bridge and was
        // cached under the entry URL -- the server-rendered timetable (no such iframe) kept
        // working while the AJAX-rendered grade and exam pages never did. Android's
        // evaluateJavascript injects into the main frame only; this matches it.
        controller.addUserScript(
            WKUserScript(source: watchdog, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        controller.addUserScript(
            WKUserScript(source: guardedAdapter, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )

        context.coordinator.applyAppearance(to: webView, isDark: isDark)

        // Replay the persisted session cookie before the first navigation, mirroring
        // `PortalSessionStore.restoreToWebView`. The completion runs after the WebView's own
        // cookie store has been populated; loading before then bounces off a login redirect.
        //
        // The request bypasses the local cache on purpose (Android sets LOAD_NO_CACHE). The grade
        // and exam pages are an HTML shell whose real rows arrive from a follow-up XHR; serving a
        // cached shell whose scripts then run against stale state was one of the ways those two
        // pages spun forever on iOS.
        if let target = URL(string: url) {
            // Android disables network images for every hidden reader. Match that policy with a
            // WebKit content rule so a timetable fetch does not compete with portal banners and
            // avatars on a phone hotspot. Rule compilation is cached by WebKit; a bounded fallback
            // still starts the page if the rule store is unexpectedly unavailable.
            let imageRule = """
            [{"trigger":{"url-filter":".*","resource-type":["image"]},"action":{"type":"block"}}]
            """
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "PalmAcademic.BlockPortalImages.v1",
                encodedContentRuleList: imageRule
            ) { rule, _ in
                DispatchQueue.main.async {
                    if let rule { controller.add(rule) }
                    context.coordinator.beginInitialLoad(webView, target: target)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                context.coordinator.beginInitialLoad(webView, target: target)
            }
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyAppearance(to: webView, isDark: isDark)
        // Only a token change arriving AFTER the initial entry load has actually started is a real
        // reload request. The screen mounts the reader and immediately bumps the token for its
        // first background fetch; honoring that bump before the cookie-restore completion fires
        // either no-ops (nothing loaded yet) or, worse on slow networks, cancels the entry document
        // after its AJAX state machine has started -- which wedged the grade and exam pages, whose
        // data only exists after that state machine runs.
        if context.coordinator.initialLoadStarted, context.coordinator.refreshToken != refreshToken {
            context.coordinator.refreshToken = refreshToken
            context.coordinator.loadFresh(webView)
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
        // `perform` needs JavaScript string *literals*, not the decoded Swift string. Returning
        // `array[0]` here produced `perform(semester,2025)` instead of
        // `perform("semester","2025")`, so every filter/action silently failed in WebKit.
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        return literal
    }

    final class BridgeHandler: NSObject, WKScriptMessageHandler {
        static let name = "PalmAcademicBridge"
        weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let json = message.body as? String else { return }
            // The watchdog's report. It is shaped like a page payload so it travels the same
            // channel, but it is recognised before parsing because there is nothing to render.
            if let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
               let reason = object["portalDiagnostic"] as? String {
                coordinator?.parent.onDiagnostic(reason)
                return
            }
            guard let page = MaterialPageParser.parse(json) else { return }
            coordinator?.markPublished()
            // Key the cache by the REQUESTED url (the reader's own `url`), not
            // `message.webView.url`. The portal redirects the entry pages, so the post-redirect
            // URL differs from the one the screen and the background prefetcher look the cache up
            // with; keying on the redirected URL made every save unfindable, so every revisit --
            // and the first-login baseline -- cold-loaded. Android keys its cache the same way.
            //
            // Only pages that actually contain data are cached. The adapter also publishes interim
            // "暂无…" skeletons while the entry's own XHR is still in flight; caching those made
            // the next visit open on an empty page and stay there until a refresh happened to win
            // the race.
            if let parent = coordinator?.parent,
               QuickEntryBaseline.hasData(page: page, nativeType: parent.nativeType) {
                MaterialPageCache.save(url: parent.url, json: json)
            }
            if let parent = coordinator?.parent {
                parent.onContent(page, json)
            }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MaterialReaderView
        var refreshToken: Int
        var actionToken: Int
        /// False until the entry URL has actually been handed to the WebView (the load waits for
        /// the cookie restore). A refresh-token bump observed before then is the screen's initial
        // fetch, not a reload, and must not cancel the entry load.
        var initialLoadStarted = false
        private var initialRestoreRequested = false
        weak var bridgeHandler: BridgeHandler?
        /// Tells the page that a payload has been delivered, so the injected watchdog can stop
        /// reporting a failure that has in fact been resolved.
        private var didPublish = false
        /// A single native retry makes transient hotspot drops match Android WebView's practical
        /// behaviour without hiding a persistent failure behind an endless spinner.
        private var transientRetryCount = 0

        init(parent: MaterialReaderView) {
            self.parent = parent
            self.refreshToken = parent.refreshToken
            self.actionToken = parent.action?.token ?? -1
        }

        func markPublished() {
            guard !didPublish else { return }
            didPublish = true
            transientRetryCount = 0
        }

        @MainActor
        func beginInitialLoad(_ webView: WKWebView, target: URL) {
            guard !initialRestoreRequested else { return }
            initialRestoreRequested = true
            SessionStore.shared.restoreToWebView { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.loadFresh(webView, target: target)
            }
        }

        func loadFresh(_ webView: WKWebView, target: URL? = nil, resetRetry: Bool = true) {
            guard let target = target ?? URL(string: parent.url) else {
                parent.onLoading(false)
                parent.onError("页面地址无效")
                return
            }
            if resetRetry { transientRetryCount = 0 }
            initialLoadStarted = true
            webView.load(URLRequest(
                url: target,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 60
            ))
        }

        func applyAppearance(to webView: WKWebView, isDark: Bool) {
            // Mirrors `configurePortalWebDarkening`; only a light/dark document style is applied so
            // the adapter keeps reading the same DOM.
            webView.overrideUserInterfaceStyle = isDark ? .dark : .light
        }

        private func injectReader(_ webView: WKWebView) {
            let adapter = parent.adapterScript
            guard !adapter.isEmpty else { return }
            // The document-end user script already installed it on the first load. This is the
            // back/forward-cache and mid-session-navigation path, where a restored document does
            // not re-run document-end scripts, so the adapter has to be pushed in by hand.
            webView.evaluateJavaScript("!!window.PalmAcademicAdapter") { [weak self] result, _ in
                guard let self else { return }
                let installed = (result as? Bool) ?? false
                if installed {
                    // A short redirect document can install the adapter global before its body is
                    // observable. Calling publish again makes that half-initialized state recover
                    // as soon as commit/finish sees the final DOM, instead of treating "installed"
                    // as proof that a payload was already delivered.
                    webView.evaluateJavaScript(
                        "window.PalmAcademicAdapter.publish && window.PalmAcademicAdapter.publish();",
                        completionHandler: nil
                    )
                    return
                }
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
                  window.__portalPublished = true;
                  window.webkit.messageHandlers.\(BridgeHandler.name).postMessage(JSON.stringify(payload));
                },
                report: function(reason) {
                  window.webkit.messageHandlers.\(BridgeHandler.name).postMessage(JSON.stringify({portalDiagnostic: String(reason)}));
                }
              };
            }
            """
            let adapter = parent.adapterScript
            let guarded = """
            try {
            \(adapter)
            } catch (error) {
              if (window.PalmAcademicHost && window.PalmAcademicHost.report) {
                window.PalmAcademicHost.report('适配器执行出错：' + (error && error.message ? error.message : String(error)));
              }
            }
            """
            webView.evaluateJavaScript(hostAPI) { _, _ in
                webView.evaluateJavaScript(guarded, completionHandler: nil)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            initialLoadStarted = true
            didPublish = false
            parent.onLoading(true)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            let currentURL = webView.url?.absoluteString ?? ""
            if AuthRepository.isLoginPage("", finalURL: currentURL) {
                parent.onLoading(false)
                parent.onSessionExpired()
                return
            }
            // The first installation belongs exclusively to the document-end user script. At
            // didCommit the final document frequently has no body yet; injecting here let the
            // adapter create its global and then throw while attaching its MutationObserver. The
            // later document-end script saw that global and returned, yielding the misleading
            // "adapter loaded but no content" failure.
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
            parent.onLoading(false)
            // Back/forward-cache fallback. A normal navigation was already installed safely by
            // the document-end script; `injectReader` only republishes in that case.
            injectReader(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleFailure(in: webView, error: error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            handleFailure(in: webView, error: error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            handleFailure(
                in: webView,
                error: NSError(
                    domain: WKErrorDomain,
                    code: WKError.Code.webContentProcessTerminated.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "网页进程已终止"]
                )
            )
        }

        private func handleFailure(in webView: WKWebView, error: Error) {
            let nsError = error as NSError
            let retryableCodes: Set<Int> = [
                NSURLErrorTimedOut,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorCannotFindHost,
                NSURLErrorDNSLookupFailed,
                WKError.Code.webContentProcessTerminated.rawValue
            ]
            if transientRetryCount == 0,
               (nsError.domain == NSURLErrorDomain || nsError.domain == WKErrorDomain),
               retryableCodes.contains(nsError.code) {
                transientRetryCount = 1
                parent.onLoading(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak webView] in
                    guard let self, let webView else { return }
                    self.loadFresh(webView, resetRetry: false)
                }
                return
            }
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
