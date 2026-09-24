package cn.edu.cupk.portalreader

import android.annotation.SuppressLint
import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.webkit.ConsoleMessage
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import android.widget.Toolbar
import androidx.activity.ComponentActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.setPadding

class WebLoginActivity : PortalActivity() {
    private lateinit var webView: WebView
    private lateinit var progress: ProgressBar
    private lateinit var status: TextView

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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
            title = "网页登录"
            subtitle = Uri.parse(PortalConfig.ORIGIN).authority.orEmpty()
            setNavigationIcon(R.drawable.ic_arrow_back)
            setNavigationOnClickListener { finishPortalActivity() }
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
            setSubtitleTextColor(colors.secondaryText)
            navigationIcon?.setTint(colors.text)
            elevation = 0f
        }
        root.addView(toolbar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, toolbarHeight))

        progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            isIndeterminate = false
            max = 100
        }
        root.addView(progress, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (3 * density).toInt()))

        webView = WebView(this).apply {
            setBackgroundColor(colors.webBackground)
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f)
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.cacheMode = WebSettings.LOAD_NO_CACHE
            settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            settings.javaScriptCanOpenWindowsAutomatically = true
            settings.setSupportMultipleWindows(false)
            settings.useWideViewPort = true
            settings.loadWithOverviewMode = false
            settings.builtInZoomControls = false
            configurePortalWebDarkening(settings, darkTheme)
        }
        root.addView(webView)

        status = TextView(this).apply {
            visibility = View.GONE
            setTextColor(colors.errorText)
            setBackgroundColor(colors.errorBackground)
            textSize = 14f
            setPadding((16 * density).toInt())
        }
        root.addView(status, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        setContentView(root)
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(0, 0, 0, bars.bottom)
            toolbar.setPadding(toolbar.paddingLeft, bars.top, toolbar.paddingRight, toolbar.paddingBottom)
            toolbar.layoutParams = toolbar.layoutParams.apply { height = toolbarHeight + bars.top }
            insets
        }

        configureBrowser()
        val cookies = CookieManager.getInstance().apply {
            setAcceptCookie(true)
            setAcceptThirdPartyCookies(webView, true)
        }
        // 网页登录始终从新的临时会话开始，避免已失效 SESSION 让登录页停在空状态。
        PortalSessionCoordinator.clear()
        PortalSessionStore.clear()
        cookies.removeAllCookies {
            runOnUiThread {
                cookies.flush()
                webView.clearCache(true)
                webView.loadUrl(PortalConfig.LOGIN)
            }
        }
    }

    private fun configureBrowser() {
        webView.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView, newProgress: Int) {
                progress.progress = newProgress
                progress.visibility = if (newProgress >= 100) View.GONE else View.VISIBLE
            }

            override fun onConsoleMessage(consoleMessage: ConsoleMessage): Boolean {
                Log.d("PortalWebLogin", "${consoleMessage.message()} @${consoleMessage.lineNumber()}")
                return true
            }
        }
        webView.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                status.visibility = View.GONE
                progress.visibility = View.VISIBLE
            }

            override fun onPageFinished(view: WebView, finishedUrl: String?) {
                CookieManager.getInstance().flush()
                if (finishedUrl?.startsWith(PortalConfig.HOME) == true) {
                    PortalSessionStore.captureFromWebView()
                    setResult(Activity.RESULT_OK)
                    finish()
                    @Suppress("DEPRECATION")
                    overridePendingTransition(0, 0)
                }
            }

            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val uri = request.url
                val portal = Uri.parse(PortalConfig.ORIGIN)
                return uri.scheme != portal.scheme || uri.host != portal.host || uri.port != portal.port
            }

            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) showError(error.description?.toString().orEmpty().ifBlank { "网页登录加载失败" })
            }

            override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, errorResponse: WebResourceResponse) {
                if (request.isForMainFrame) showError("网页服务器返回 ${errorResponse.statusCode}")
            }
        }
    }

    private fun showError(message: String) {
        progress.visibility = View.GONE
        status.text = message
        status.visibility = View.VISIBLE
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
    }

    override fun onDestroy() {
        webView.stopLoading()
        webView.webChromeClient = null
        webView.webViewClient = WebViewClient()
        webView.destroy()
        super.onDestroy()
    }
}
