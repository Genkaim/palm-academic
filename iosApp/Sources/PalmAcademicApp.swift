import SwiftUI
import WebKit

@main
struct PalmAcademicApp: App {
    var body: some Scene {
        WindowGroup {
            PortalContentView()
        }
    }
}

@MainActor
final class PortalWebModel: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var title = "掌上教务"

    private let homeURL = URL(string: "https://eams.cupk.edu.cn/student/login")!

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: homeURL))
    }

    func goHome() {
        webView.load(URLRequest(url: homeURL))
    }

    func refresh() {
        webView.reload()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        updateState(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateState(webView)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        updateState(webView)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        updateState(webView)
    }

    private func updateState(_ webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        title = webView.title?.isEmpty == false ? webView.title! : "掌上教务"
    }
}

struct PortalWebView: UIViewRepresentable {
    @ObservedObject var model: PortalWebModel

    func makeUIView(context: Context) -> WKWebView {
        model.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct PortalContentView: View {
    @StateObject private var model = PortalWebModel()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                PortalWebView(model: model)
                if model.isLoading {
                    ProgressView()
                        .padding(10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                }
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        model.webView.goBack()
                    } label: {
                        Label("后退", systemImage: "chevron.backward")
                    }
                    .disabled(!model.canGoBack)

                    Button {
                        model.webView.goForward()
                    } label: {
                        Label("前进", systemImage: "chevron.forward")
                    }
                    .disabled(!model.canGoForward)

                    Spacer()

                    Button(action: model.goHome) {
                        Label("首页", systemImage: "house")
                    }

                    Button(action: model.refresh) {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }
}

