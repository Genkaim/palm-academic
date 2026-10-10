package cn.edu.cupk.portalreader

import android.webkit.CookieManager
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

class WebViewCookieJar : CookieJar {
    private val manager: CookieManager
        get() = CookieManager.getInstance().apply { setAcceptCookie(true) }

    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        cookies.forEach { manager.setCookie(url.toString(), it.toString()) }
        manager.flush()
        // 保留每个 cookie 的 domain/path：CAS 与门户的同名 cookie 不能折叠成一条。
        PortalSessionStore.mergeCookies(cookies.map(PersistedCookie::fromOkHttp))
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        val now = System.currentTimeMillis()
        // 持久 cookie 严格按各自的 domain/path 匹配请求 URL——TGC 只发给 CAS，SESSION 只发给门户。
        val persisted = PortalSessionStore.persistedCookies()
            .asSequence()
            .filter { it.expiresAt == Long.MAX_VALUE || it.expiresAt > now }
            .filter {
                it.matches(
                    host = url.host,
                    requestPath = url.encodedPath.ifEmpty { "/" },
                    https = url.scheme == "https"
                )
            }
            .map { it.toOkHttpCookie() }
            .toList()
        // CookieManager 里的实时值优先（页面 JS 或最新跳转可能刚种过 cookie）。
        val live = manager.getCookie(url.toString())
            ?.split(';')
            ?.mapNotNull { Cookie.parse(url, it.trim()) }
            .orEmpty()
        if (persisted.isEmpty()) {
            // 旧版本只留了扁平 header：不区分域地兜底，保证升级用户不掉登录。
            val legacy = PortalSessionStore.persistedCookieHeader()
                ?.split(';')
                ?.mapNotNull { Cookie.parse(url, it.trim()) }
                .orEmpty()
            return (legacy + live)
                .associateBy { it.name }
                .values
                .toList()
        }
        return (persisted + live)
            .associateBy { it.name }
            .values
            .toList()
    }
}

object PortalHttp {
    val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .cookieJar(WebViewCookieJar())
            .followRedirects(true)
            .followSslRedirects(true)
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .callTimeout(40, TimeUnit.SECONDS)
            .build()
    }

    // Every login path persists SESSION before it reports success, so the app-private copy is
    // the authoritative cold-start signal. Querying CookieManager here would initialize the
    // system WebView even for a signed-out launch and noticeably delay the first frame.
    fun hasSessionCookie(): Boolean = PortalSessionStore.hasPersistedSession()

    fun clearSession(done: () -> Unit = {}) {
        PortalSessionStore.clear()
        CookieManager.getInstance().removeAllCookies {
            CookieManager.getInstance().flush()
            done()
        }
    }
}
