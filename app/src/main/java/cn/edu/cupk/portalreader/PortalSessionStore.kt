package cn.edu.cupk.portalreader

import android.app.Application
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.resume

/** Persists the EAMS session cookie in app-private storage across process restarts. */
object PortalSessionStore {
    private const val PREFS = "academic_session"
    private const val KEY_COOKIE_HEADER = "cookie_header"
    private lateinit var appContext: Context

    fun initialize(context: Context) {
        appContext = context.applicationContext
    }

    fun captureFromWebView() {
        if (!::appContext.isInitialized) return
        val header = CookieManager.getInstance().getCookie(PortalConfig.BASE).orEmpty()
        // CookieManager can briefly return an empty value while WebView is starting.
        // Only an explicit logout/expiry path may clear the persisted session.
        if (header.isNotBlank()) saveCookieHeader(header)
    }

    fun saveCookieHeader(header: String) {
        if (!::appContext.isInitialized || header.isBlank()) return
        appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_COOKIE_HEADER, header)
            .commit()
    }

    @Synchronized
    fun mergeCookies(values: Map<String, String?>) {
        if (!::appContext.isInitialized || values.isEmpty()) return
        val cookies = linkedMapOf<String, String>()
        persistedCookieHeader()?.split(';')?.forEach { part ->
            val name = part.substringBefore('=', "").trim()
            val value = part.substringAfter('=', "").trim()
            if (name.isNotBlank()) cookies[name] = value
        }
        values.forEach { (name, value) ->
            if (value == null) cookies.remove(name) else cookies[name] = value
        }
        if (cookies.isNotEmpty()) {
            saveCookieHeader(cookies.entries.joinToString("; ") { "${it.key}=${it.value}" })
        }
    }

    fun persistedCookieHeader(): String? {
        if (!::appContext.isInitialized) return null
        return appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_COOKIE_HEADER, null)
            ?.takeIf { it.isNotBlank() }
    }

    fun hasPersistedSession(): Boolean =
        persistedCookieHeader()?.split(';')?.any { it.trim().startsWith("SESSION=") } == true

    fun restoreToWebView(onComplete: () -> Unit = {}): Boolean {
        if (!::appContext.isInitialized) return false
        val header = persistedCookieHeader() ?: return false
        val cookies = header.split(';').map(String::trim).filter { it.contains('=') }
        if (cookies.isEmpty()) return false
        val manager = CookieManager.getInstance().apply { setAcceptCookie(true) }
        val currentCookies = manager.getCookie(PortalConfig.BASE).orEmpty()
            .split(';')
            .map(String::trim)
            .filter { it.contains('=') }
            .associate { it.substringBefore('=').trim() to it.substringAfter('=').trim() }
        val cookiesAlreadyInstalled = cookies.all { cookie ->
            currentCookies[cookie.substringBefore('=').trim()] == cookie.substringAfter('=').trim()
        }
        if (cookiesAlreadyInstalled) {
            if (Looper.myLooper() == Looper.getMainLooper()) onComplete()
            else Handler(Looper.getMainLooper()).post(onComplete)
            return true
        }
        val install = { installCookies(cookies, onComplete) }
        if (Looper.myLooper() == Looper.getMainLooper()) install()
        else Handler(Looper.getMainLooper()).post(install)
        return true
    }

    private fun installCookies(cookies: List<String>, onComplete: () -> Unit) {
        val manager = CookieManager.getInstance().apply { setAcceptCookie(true) }
        val remaining = AtomicInteger(cookies.size)
        cookies.forEach { cookie ->
            val name = cookie.substringBefore('=').trim()
            val httpOnly = if (name == "SESSION") "; HttpOnly" else ""
            val secure = if (PortalConfig.ORIGIN.startsWith("https://")) "; Secure" else ""
            manager.setCookie(
                PortalConfig.BASE,
                "$cookie; Path=/student$secure$httpOnly; SameSite=Lax"
            ) {
                if (remaining.decrementAndGet() == 0) {
                    manager.flush()
                    onComplete()
                }
            }
        }
    }

    suspend fun restoreToWebViewAndWait(): Boolean = withContext(Dispatchers.Main.immediate) {
        suspendCancellableCoroutine { continuation ->
            val started = restoreToWebView {
                if (continuation.isActive) continuation.resume(true)
            }
            if (!started && continuation.isActive) continuation.resume(false)
        }
    }

    fun clear() {
        if (!::appContext.isInitialized) return
        appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_COOKIE_HEADER)
            .commit()
    }
}

class PalmAcademicApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        PortalThemePreferences.initialize(this)
        SchoolAdapterRepository.initialize(this)
        PortalSessionStore.initialize(this)
        PortalSessionStore.restoreToWebView()
        PortalSessionCoordinator.initialize(this)
        PortalMonitor.restore(this)
    }
}
