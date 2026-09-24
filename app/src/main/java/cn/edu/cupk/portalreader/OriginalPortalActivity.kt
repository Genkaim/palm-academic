package cn.edu.cupk.portalreader

import android.annotation.SuppressLint
import android.app.AlertDialog
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.Toast
import android.widget.Toolbar
import androidx.activity.ComponentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import kotlinx.coroutines.launch
import org.json.JSONObject

class OriginalPortalActivity : PortalActivity() {
    private lateinit var webView: WebView
    private var sessionDialogShown = false
    private var nativeNavigationStarted = false
    private var initialLoadStarted = false

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val title = intent.getStringExtra(MaterialPortalActivity.EXTRA_TITLE).orEmpty()
        val url = intent.getStringExtra(MaterialPortalActivity.EXTRA_URL).orEmpty()
        if (!url.startsWith("https://")) { finish(); return }

        useContinuousSystemBars()
        val density = resources.displayMetrics.density
        val colors = portalViewColors(this)
        val darkTheme = PortalThemePreferences.isDark(this)
        val toolbarHeight = (64 * density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(colors.webBackground)
        }
        val toolbar = Toolbar(this).apply {
            this.title = title
            setNavigationIcon(R.drawable.ic_arrow_back)
            setNavigationOnClickListener { finish() }
            background = GradientDrawable(
                GradientDrawable.Orientation.TOP_BOTTOM,
                intArrayOf(
                    colors.pageBackground,
                    colors.pageBackground,
                    (colors.pageBackground and 0x00FFFFFF) or 0x66000000,
                    Color.TRANSPARENT
                )
            )
            setTitleTextColor(colors.text)
            navigationIcon?.setTint(colors.text)
            elevation = 0f
        }
        root.addView(toolbar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, toolbarHeight))
        val progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply { max = 100 }
        root.addView(progress, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (3 * density).toInt()))
        webView = WebView(this).apply {
            setBackgroundColor(colors.webBackground)
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.cacheMode = WebSettings.LOAD_DEFAULT
            settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            // 沿用官网自己的 viewport，不把原生栏目强行压缩到固定页面宽度。
            settings.useWideViewPort = true
            settings.loadWithOverviewMode = false
            settings.setSupportZoom(true)
            settings.builtInZoomControls = true
            settings.displayZoomControls = false
            settings.layoutAlgorithm = WebSettings.LayoutAlgorithm.NORMAL
            configurePortalWebDarkening(settings, darkTheme)
        }
        root.addView(webView, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(0, 0, 0, bars.bottom)
            toolbar.setPadding(toolbar.paddingLeft, bars.top, toolbar.paddingRight, toolbar.paddingBottom)
            toolbar.layoutParams = toolbar.layoutParams.apply { height = toolbarHeight + bars.top }
            insets
        }

        CookieManager.getInstance().apply { setAcceptCookie(true); setAcceptThirdPartyCookies(webView, true) }
        webView.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView, newProgress: Int) {
                progress.progress = newProgress
                progress.visibility = if (newProgress >= 100) android.view.View.GONE else android.view.View.VISIBLE
            }
        }
        webView.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                progress.visibility = android.view.View.VISIBLE
            }
            override fun onPageFinished(view: WebView, url: String?) {
                if (url?.substringBefore('?')?.endsWith("/login") == true) {
                    showExpiredSessionDialog()
                } else {
                    PortalSessionStore.captureFromWebView()
                    PortalSessionCoordinator.markAuthenticated()
                    if (!nativeNavigationStarted && url?.startsWith(PortalConfig.HOME) == true) {
                        openThroughPortalMenu(view, title, this@OriginalPortalActivity.intent.getStringExtra(MaterialPortalActivity.EXTRA_URL).orEmpty())
                    }
                }
            }
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = request.url.scheme != "https"
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) Toast.makeText(this@OriginalPortalActivity, error.description, Toast.LENGTH_LONG).show()
            }
        }
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                PortalSessionCoordinator.state.collect { state ->
                    when (state) {
                        PortalSessionState.Checking -> startInitialLoad()
                        PortalSessionState.Ready -> startInitialLoad()
                        is PortalSessionState.Unavailable -> startInitialLoad()
                        PortalSessionState.Expired, PortalSessionState.NoSession -> showExpiredSessionDialog()
                    }
                }
            }
        }
    }

    private fun startInitialLoad() {
        if (initialLoadStarted || isFinishing || isDestroyed) return
        initialLoadStarted = true
        // 普通栏目由教务首页的原生菜单触发，保留官网自身的路由和初始化流程。
        if (!PortalSessionStore.restoreToWebView { webView.loadUrl(PortalConfig.HOME) }) {
            webView.loadUrl(PortalConfig.HOME)
        }
    }

    private fun openThroughPortalMenu(view: WebView, title: String, targetUrl: String, attempt: Int = 0) {
        if (nativeNavigationStarted || isFinishing || isDestroyed) return
        val script = """
            (function() {
              var title = ${JSONObject.quote(title)};
              var target = ${JSONObject.quote(targetUrl)};
              var targetPath = new URL(target).pathname;
              var normalize = function(value) { return (value || '').replace(/\s+/g, ' ').trim(); };
              var menuItems = Array.from(document.querySelectorAll('a.menu-item'));
              var candidate = menuItems.find(function(node) {
                return normalize(node.getAttribute('data-text') || node.textContent) === title;
              });
              if (!candidate) candidate = menuItems.find(function(node) {
                var href = node.getAttribute('href') || '';
                try { return href && new URL(href, location.href).pathname === targetPath; } catch (_) { return false; }
              });
              if (!candidate) return false;

              // 官网依据这两个属性决定是否在新浏览器标签打开。App 内统一沿用
              // 教务首页自己的菜单事件，但让结果留在当前 WebView 的原生页面壳中。
              candidate.setAttribute('browsertab', 'false');
              candidate.removeAttribute('target');

              var menuToggle = Array.from(document.querySelectorAll('button,a')).find(function(node) {
                return normalize(node.getAttribute('data-text') || node.textContent).endsWith('菜单');
              });
              if (menuToggle && !menuToggle.classList.contains('active')) menuToggle.click();
              setTimeout(function() { candidate.click(); }, 80);
              return true;
            })();
        """.trimIndent()
        view.postDelayed({
            if (nativeNavigationStarted || isFinishing || isDestroyed) return@postDelayed
            view.evaluateJavascript(script) { result ->
                if (result == "true") {
                    nativeNavigationStarted = true
                } else if (attempt < 3) {
                    openThroughPortalMenu(view, title, targetUrl, attempt + 1)
                } else {
                    nativeNavigationStarted = true
                    Toast.makeText(
                        this@OriginalPortalActivity,
                        "未在教务菜单中找到“$title”，已停留在教务首页",
                        Toast.LENGTH_LONG
                    ).show()
                }
            }
        }, if (attempt == 0) 300L else 650L)
    }

    private fun showExpiredSessionDialog() {
        if (sessionDialogShown || isFinishing || isDestroyed) return
        sessionDialogShown = true
        AlertDialog.Builder(this)
            .setTitle("登录状态已失效")
            .setMessage("教务系统登录状态已过期或账号凭据已变更，请重新登录。")
            .setCancelable(false)
            .setPositiveButton("重新登录") { _, _ ->
                PortalSessionCoordinator.clear()
                PortalHttp.clearSession {
                    runOnUiThread {
                        startActivity(
                            Intent(this, MainActivity::class.java)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                        )
                        finish()
                    }
                }
            }
            .show()
    }

    override fun onDestroy() {
        webView.stopLoading()
        webView.webChromeClient = null
        webView.webViewClient = WebViewClient()
        webView.destroy()
        super.onDestroy()
    }
}
