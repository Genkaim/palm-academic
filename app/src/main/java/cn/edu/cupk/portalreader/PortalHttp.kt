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
        PortalSessionStore.mergeCookies(
            cookies.associate { cookie ->
                cookie.name to cookie.value.takeIf { cookie.expiresAt > System.currentTimeMillis() }
            }
        )
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        val persisted = PortalSessionStore.persistedCookieHeader()
        val current = manager.getCookie(url.toString())
        // The app-private copy is the durable source of truth immediately after restart.
        return listOfNotNull(current, persisted)
            .flatMap { it.split(';') }
            .mapNotNull { Cookie.parse(url, it.trim()) }
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

    fun hasSessionCookie(): Boolean =
        CookieManager.getInstance().getCookie(PortalConfig.BASE)
            ?.contains("SESSION=") == true || PortalSessionStore.hasPersistedSession()

    fun clearSession(done: () -> Unit = {}) {
        PortalSessionStore.clear()
        CookieManager.getInstance().removeAllCookies {
            CookieManager.getInstance().flush()
            done()
        }
    }
}
