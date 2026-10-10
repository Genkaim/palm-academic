package cn.edu.cupk.portalreader

import android.annotation.SuppressLint
import android.app.AlertDialog
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.TextUtils
import android.util.Log
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

class OriginalPortalActivity : PortalActivity() {
    private lateinit var webView: WebView
    private var sessionDialogShown = false
    private var initialLoadStarted = false
    private var silentReauthenticationPending = false

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
        val headerBackground = View(this).apply {
            setBackgroundColor(colors.webBackground)
        }
        root.addView(
            headerBackground,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                controlSize + (16 * density).toInt()
            ).apply { gravity = Gravity.TOP }
        )
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
        val webViewParams = FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT
        ).apply {
            topMargin = controlSize + (16 * density).toInt()
        }
        root.addView(webView, webViewParams)

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
                progress.visibility = View.VISIBLE
                loadConfiguredPage()
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
            val webTop = bars.top + (8 * density).toInt() + controlSize + (8 * density).toInt()
            webView.setPadding(0, 0, 0, bars.bottom)
            (headerBackground.layoutParams as FrameLayout.LayoutParams).apply {
                height = webTop
                headerBackground.layoutParams = this
            }
            (webView.layoutParams as FrameLayout.LayoutParams).apply {
                topMargin = webTop
                webView.layoutParams = this
            }
            (chrome.layoutParams as FrameLayout.LayoutParams).apply {
                topMargin = bars.top + (8 * density).toInt()
                chrome.layoutParams = this
            }
            (progress.layoutParams as FrameLayout.LayoutParams).apply {
                topMargin = webTop
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
                Log.i(TAG, "Started ${url.orEmpty()}")
                progress.visibility = android.view.View.VISIBLE
            }
            override fun onPageFinished(view: WebView, url: String?) {
                Log.i(TAG, "Finished ${url.orEmpty()}")
                if (url?.substringBefore('?')?.endsWith("/login") == true) {
                    showExpiredSessionDialog()
                } else {
                    PortalSessionStore.captureFromWebView()
                    PortalSessionCoordinator.markAuthenticated()
                }
            }
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val requested = request.url
                if (requested.scheme.equals("https", ignoreCase = true)) return false

                // This portal briefly redirects its HTTPS entry URL to an HTTP URL on the same
                // host, where nginx immediately redirects back to HTTPS. Blocking that first hop
                // aborts the main frame and leaves the WebView at about:blank. Upgrade the trusted
                // same-host hop in place so the browser flow works without making an insecure
                // request or allowing arbitrary clear-text navigation.
                val targetHost = runCatching {
                    android.net.Uri.parse(
                        intent.getStringExtra(MaterialPortalActivity.EXTRA_URL).orEmpty()
                    ).host
                }.getOrNull()
                if (requested.scheme.equals("http", ignoreCase = true) &&
                    requested.host.equals(targetHost, ignoreCase = true)
                ) {
                    val upgraded = requested.buildUpon().scheme("https").build().toString()
                    Log.i(TAG, "Upgrading portal redirect to $upgraded")
                    view.loadUrl(upgraded)
                    return true
                }
                Log.w(TAG, "Blocked external navigation to ${requested.scheme.orEmpty()}")
                return true
            }
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) {
                    Log.e(TAG, "Main-frame error ${error.errorCode}: ${error.description} (${request.url})")
                    Toast.makeText(this@OriginalPortalActivity, error.description, Toast.LENGTH_LONG).show()
                }
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
        loadConfiguredPage()
    }

    private fun loadConfiguredPage() {
        val targetUrl = intent.getStringExtra(MaterialPortalActivity.EXTRA_URL).orEmpty()
        if (!targetUrl.startsWith("https://")) return
        if (!PortalSessionStore.restoreToWebView { webView.loadUrl(targetUrl) }) {
            webView.loadUrl(targetUrl)
        }
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

    private companion object {
        const val TAG = "OriginalPortal"
    }
}
