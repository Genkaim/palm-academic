package cn.edu.cupk.portalreader

import android.annotation.SuppressLint
import android.app.AlertDialog
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
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
    private var silentReauthenticationPending = false

    private fun samePortalLocation(first: String, second: String): Boolean = runCatching {
        val left = android.net.Uri.parse(first)
        val right = android.net.Uri.parse(second)
        left.scheme.equals(right.scheme, true) &&
            left.host.equals(right.host, true) &&
            left.path.orEmpty().trimEnd('/') == right.path.orEmpty().trimEnd('/') &&
            left.query.orEmpty() == right.query.orEmpty()
    }.getOrDefault(false)

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
        val controlSize = (48 * density).toInt()
        val controlGap = (10 * density).toInt()
        val edgeMargin = (16 * density).toInt()
        val chromeColor = if (darkTheme) {
            Color.argb(232, 28, 28, 30)
        } else {
            Color.argb(238, 255, 255, 255)
        }
        fun chromeBackground(radius: Float) = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = radius
            setColor(chromeColor)
            setStroke((density * 0.75f).coerceAtLeast(1f).toInt(), Color.argb(38, 128, 128, 128))
        }
        val root = FrameLayout(this).apply {
            setBackgroundColor(colors.webBackground)
        }
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
            settings.javaScriptCanOpenWindowsAutomatically = true
            settings.setSupportMultipleWindows(false)
            settings.layoutAlgorithm = WebSettings.LayoutAlgorithm.NORMAL
            configurePortalWebDarkening(settings, darkTheme)
        }
        root.addView(
            webView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        )

        val progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
        }
        val progressParams = FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            (3 * density).toInt()
        ).apply {
            gravity = Gravity.TOP
            marginStart = edgeMargin
            marginEnd = edgeMargin
        }
        root.addView(progress, progressParams)

        val chrome = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val back = ImageButton(this).apply {
            setImageResource(R.drawable.ic_arrow_back)
            drawable.setTint(colors.text)
            background = chromeBackground(controlSize / 2f)
            elevation = 8 * density
            contentDescription = "返回"
            setOnClickListener { finish() }
        }
        chrome.addView(back, LinearLayout.LayoutParams(controlSize, controlSize))

        val titleView = TextView(this).apply {
            text = title
            setTextColor(colors.text)
            textSize = 15f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            gravity = Gravity.CENTER_VERTICAL
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            maxWidth = (resources.displayMetrics.widthPixels * 0.58f).toInt()
            background = chromeBackground(controlSize / 2f)
            elevation = 8 * density
            setPadding((16 * density).toInt(), 0, (16 * density).toInt(), 0)
        }
        chrome.addView(
            titleView,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, controlSize).apply {
                marginStart = controlGap
            }
        )
        chrome.addView(View(this), LinearLayout.LayoutParams(0, 1, 1f))

        val refresh = ImageButton(this).apply {
            setImageResource(R.drawable.ic_refresh)
            drawable.setTint(colors.text)
            background = chromeBackground(controlSize / 2f)
            elevation = 8 * density
            contentDescription = "刷新"
            setOnClickListener {
                nativeNavigationStarted = false
                progress.visibility = View.VISIBLE
                if (!PortalSessionStore.restoreToWebView { webView.loadUrl(PortalConfig.HOME) }) {
                    webView.loadUrl(PortalConfig.HOME)
                }
            }
        }
        chrome.addView(
            refresh,
            LinearLayout.LayoutParams(controlSize, controlSize).apply { marginStart = controlGap }
        )
        val chromeParams = FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            controlSize
        ).apply {
            gravity = Gravity.TOP
            marginStart = edgeMargin
            marginEnd = edgeMargin
        }
        root.addView(chrome, chromeParams)
        setContentView(root)
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            webView.setPadding(0, 0, 0, bars.bottom)
            (chrome.layoutParams as FrameLayout.LayoutParams).apply {
                topMargin = bars.top + (8 * density).toInt()
                chrome.layoutParams = this
            }
            (progress.layoutParams as FrameLayout.LayoutParams).apply {
                topMargin = bars.top + controlSize + (14 * density).toInt()
                progress.layoutParams = this
            }
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
                    val targetUrl = this@OriginalPortalActivity.intent
                        .getStringExtra(MaterialPortalActivity.EXTRA_URL).orEmpty()
                    if (!nativeNavigationStarted && url != null && samePortalLocation(url, PortalConfig.HOME)) {
                        if (samePortalLocation(targetUrl, PortalConfig.HOME)) {
                            nativeNavigationStarted = true
                        } else {
                            openThroughPortalMenu(view, title, targetUrl)
                        }
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
                        PortalSessionState.Checking -> if (!silentReauthenticationPending) startInitialLoad()
                        PortalSessionState.Ready -> {
                            if (silentReauthenticationPending) {
                                silentReauthenticationPending = false
                                initialLoadStarted = false
                                nativeNavigationStarted = false
                            }
                            startInitialLoad()
                        }
                        is PortalSessionState.Unavailable -> startInitialLoad()
                        PortalSessionState.Expired, PortalSessionState.NoSession -> {
                            silentReauthenticationPending = false
                            showExpiredSessionDialog()
                        }
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
              var links = Array.from(document.querySelectorAll('a[href]'));
              var menuItems = links.filter(function(node) {
                return !!node.closest('nav, .menu, .sidebar, [class*="menu"], [class*="nav"], [role="navigation"]') ||
                  /menu|nav/i.test(node.className || '');
              });
              if (menuItems.length === 0) menuItems = links;
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
                    view.loadUrl(targetUrl)
                }
            }
        }, if (attempt == 0) 300L else 650L)
    }

    private fun showExpiredSessionDialog() {
        if (sessionDialogShown || isFinishing || isDestroyed) return
        if (supportsSilentPasswordReauthentication() && PortalHttp.hasSessionCookie()) {
            silentReauthenticationPending = true
            PortalSessionCoordinator.validate(application, force = true)
            return
        }
        sessionDialogShown = true
        if (requiresCaptchaReauthentication()) {
            markCaptchaReauthenticationRequired()
            PortalSessionCoordinator.clear()
            PortalHttp.clearSession {
                runOnUiThread {
                    startActivity(
                        Intent(this, MainActivity::class.java)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                            .putExtra(MainActivity.EXTRA_CAPTCHA_REAUTHENTICATION, true)
                    )
                    finish()
                }
            }
            return
        }
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
