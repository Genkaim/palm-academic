package cn.edu.cupk.portalreader

import android.app.Application
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.Cookie
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.resume

/**
 * 一条带完整作用域的持久化 cookie。
 *
 * CAS 类学校的会话天然跨域：门户的 SESSION 在门户主机，TGC/JSESSIONID 在 CAS 主机，二者还
 * 可能同名（两个主机都种 SESSION/JSESSIONID）。早期版本只持久化扁平的 `name=value` 头，恢复
 * 时把所有 cookie 装到同一个主机，CAS 永远收不到 TGC，会话一过期就无法静默换票，网页被踢回
 * 登录页。记录必须保留 domain/path/secure/httpOnly 才能按真实作用域还原（与 iOS 的
 * CookieRecord v2 对应）。
 */
data class PersistedCookie(
    val name: String,
    val value: String,
    val domain: String,
    val path: String,
    val secure: Boolean,
    val httpOnly: Boolean,
    /** hostOnly=false 表示原始 Set-Cookie 带 Domain 属性，可对子域生效。 */
    val hostOnly: Boolean,
    /** OkHttp 约定：会话级 cookie 为 Long.MAX_VALUE。 */
    val expiresAt: Long
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("name", name)
        put("value", value)
        put("domain", domain)
        put("path", path)
        put("secure", secure)
        put("httpOnly", httpOnly)
        put("hostOnly", hostOnly)
        put("expiresAt", expiresAt)
    }

    fun matches(host: String, requestPath: String, https: Boolean): Boolean {
        val normalisedHost = host.lowercase()
        val normalisedDomain = domain.lowercase()
        val domainMatches = if (hostOnly) {
            normalisedHost == normalisedDomain
        } else {
            normalisedHost == normalisedDomain || normalisedHost.endsWith(".$normalisedDomain")
        }
        val cookiePath = path.ifEmpty { "/" }
        val pathMatches = requestPath.startsWith(cookiePath)
        val schemeMatches = !secure || https
        return domainMatches && pathMatches && schemeMatches
    }

    /** 重建为 OkHttp cookie，供 HTTP 客户端按作用域装载。 */
    fun toOkHttpCookie(): Cookie {
        // Cookie.Builder 始终按 hostOnly 构建；本项目学校全部是精确主机会话，无跨子域 cookie。
        val builder = Cookie.Builder()
            .domain(domain)
            .name(name)
            .value(value)
            .path(path)
            .expiresAt(expiresAt)
        if (secure) builder.secure()
        if (httpOnly) builder.httpOnly()
        return builder.build()
    }

    companion object {
        fun fromJson(json: JSONObject): PersistedCookie = PersistedCookie(
            name = json.getString("name"),
            value = json.getString("value"),
            domain = json.getString("domain"),
            path = json.optString("path", "/").ifEmpty { "/" },
            secure = json.optBoolean("secure", false),
            httpOnly = json.optBoolean("httpOnly", false),
            // 缺省按 hostOnly 处理：旧记录本来就没有域作用域信息。
            hostOnly = json.optBoolean("hostOnly", true),
            expiresAt = json.optLong("expiresAt", Long.MAX_VALUE)
        )

        fun fromOkHttp(cookie: Cookie): PersistedCookie = PersistedCookie(
            name = cookie.name,
            value = cookie.value,
            domain = cookie.domain,
            path = cookie.path.ifEmpty { "/" },
            secure = cookie.secure,
            httpOnly = cookie.httpOnly,
            hostOnly = cookie.hostOnly,
            expiresAt = if (cookie.persistent) cookie.expiresAt else Long.MAX_VALUE
        )
    }
}

/** Persists the portal session cookies in app-private storage across process restarts. */
object PortalSessionStore {
    private const val PREFS = "academic_session"
    private const val KEY_COOKIE_HEADER = "cookie_header"
    private const val KEY_COOKIE_RECORDS = "cookie_records_v2"
    private lateinit var appContext: Context

    fun initialize(context: Context) {
        appContext = context.applicationContext
    }

    private val prefs
        get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // region 读取

    @Synchronized
    fun persistedCookies(): List<PersistedCookie> {
        if (!::appContext.isInitialized) return emptyList()
        val raw = prefs.getString(KEY_COOKIE_RECORDS, null) ?: return emptyList()
        val array = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
        val now = System.currentTimeMillis()
        return (0 until array.length()).mapNotNull { index ->
            runCatching { PersistedCookie.fromJson(array.getJSONObject(index)) }.getOrNull()
        }.filter { it.value.isNotBlank() && (it.expiresAt == Long.MAX_VALUE || it.expiresAt > now) }
    }

    fun persistedCookieHeader(): String? {
        if (!::appContext.isInitialized) return null
        val records = persistedCookies()
        if (records.isNotEmpty()) {
            // 每个 (domain,name) 一条；跨域同名 cookie（CAS 与门户都叫 SESSION）都要保留。
            return records.asSequence()
                .distinctBy { it.domain.lowercase() + "|" + it.name.lowercase() }
                .joinToString("; ") { "${it.name}=${it.value}" }
                .takeIf { it.isNotBlank() }
        }
        return prefs.getString(KEY_COOKIE_HEADER, null)?.takeIf { it.isNotBlank() }
    }

    fun hasPersistedSession(): Boolean = persistedCookieHeader() != null

    // endregion

    // region 写入

    /** 登录主路径的整包写入：以本次握手拿到的完整 cookie 集替换旧会话。 */
    @Synchronized
    fun saveCookies(cookies: List<PersistedCookie>) {
        if (!::appContext.isInitialized) return
        val live = cookies.filter { it.value.isNotBlank() }
        if (live.isEmpty()) return
        val records = JSONArray()
        live.forEach { records.put(it.toJson()) }
        val header = live.asSequence()
            .distinctBy { it.domain.lowercase() + "|" + it.name.lowercase() }
            .joinToString("; ") { "${it.name}=${it.value}" }
        prefs.edit()
            .putString(KEY_COOKIE_RECORDS, records.toString())
            .putString(KEY_COOKIE_HEADER, header)
            .commit()
    }

    @Synchronized
    fun saveCookieHeader(header: String) {
        if (!::appContext.isInitialized || header.isBlank()) return
        // 显式 header 只在旧流程/兜底里出现：保留 header，同时不清空已有 records。
        prefs.edit().putString(KEY_COOKIE_HEADER, header).commit()
    }

    /**
     * 浏览过程中服务端新种/更新的 cookie 增量合并（OkHttp 路径，带完整域）。
     * 键为 domain|path|name，跨域同名 cookie 各自独立。
     */
    @Synchronized
    fun mergeCookies(cookies: List<PersistedCookie>) {
        if (!::appContext.isInitialized || cookies.isEmpty()) return
        val merged = LinkedHashMap<String, PersistedCookie>()
        // 以 records 为基底；records 缺失时兼容旧版扁平 header（作用域落到学校主域）。
        persistedCookies().forEach { merged[recordKey(it)] = it }
        if (merged.isEmpty()) {
            legacyHeaderCookies().forEach { merged[recordKey(it)] = it }
        }
        cookies.forEach { cookie ->
            if (cookie.value.isBlank()) {
                merged.remove(recordKey(cookie))
            } else {
                merged[recordKey(cookie)] = cookie
            }
        }
        saveCookies(merged.values.toList())
    }

    private fun recordKey(cookie: PersistedCookie): String =
        "${cookie.domain.lowercase()}|${cookie.path.lowercase()}|${cookie.name.lowercase()}"

    /** 旧版本（只有扁平 header）升级时的兼容恢复：域取学校主域，路径取会话路径。 */
    private fun legacyHeaderCookies(): List<PersistedCookie> {
        val header = prefs.getString(KEY_COOKIE_HEADER, null) ?: return emptyList()
        val host = runCatching { java.net.URI(PortalConfig.BASE).host }.getOrNull()
            ?.takeIf { it.isNotBlank() }
            ?: return emptyList()
        return header.split(';').map(String::trim).filter { it.contains('=') }.map { pair ->
            val name = pair.substringBefore('=').trim()
            val value = pair.substringAfter('=').trim()
            PersistedCookie(
                name = name,
                value = value,
                domain = host,
                path = PortalConfig.SESSION_PATH,
                secure = PortalConfig.SESSION_SCOPE.startsWith("https://"),
                httpOnly = name.equals("SESSION", ignoreCase = true),
                hostOnly = true,
                expiresAt = Long.MAX_VALUE
            )
        }.filter { it.value.isNotBlank() }
    }

    // endregion

    // region WebView 恢复

    /**
     * 把持久化 cookie 装进系统 WebView。records 存在时严格按每条 cookie 的 domain/path
     * 安装（CAS 的 TGC 必须装到 CAS 主机）；否则回退旧的单作用域逻辑。
     */
    fun restoreToWebView(onComplete: () -> Unit = {}): Boolean {
        if (!::appContext.isInitialized) return false
        val records = persistedCookies()
        if (records.isNotEmpty()) {
            installRecordCookies(records, onComplete)
            return true
        }
        val header = prefs.getString(KEY_COOKIE_HEADER, null) ?: return false
        val cookies = header.split(';').map(String::trim).filter { it.contains('=') }
        if (cookies.isEmpty()) return false
        installHeaderCookies(cookies, onComplete)
        return true
    }

    private fun installRecordCookies(records: List<PersistedCookie>, onComplete: () -> Unit) {
        val manager = CookieManager.getInstance().apply { setAcceptCookie(true) }
        val ready = records.all { cookie ->
            val scope = "https://${cookie.domain}${cookie.path.ifEmpty { "/" }}"
            val current = manager.getCookie(scope).orEmpty()
                .split(';').map(String::trim)
                .any { it.equals("${cookie.name}=${cookie.value}", ignoreCase = false) }
            current
        }
        if (ready) {
            dispatch(onComplete)
            return
        }
        val remaining = AtomicInteger(records.size)
        records.forEach { cookie ->
            manager.setCookie(cookie.installUrl(), cookie.toSetCookieValue()) {
                if (remaining.decrementAndGet() == 0) {
                    manager.flush()
                    onComplete()
                }
            }
        }
    }

    private fun installHeaderCookies(cookies: List<String>, onComplete: () -> Unit) {
        val manager = CookieManager.getInstance().apply { setAcceptCookie(true) }
        val currentCookies = manager.getCookie(PortalConfig.SESSION_SCOPE).orEmpty()
            .split(';')
            .map(String::trim)
            .filter { it.contains('=') }
            .associate { it.substringBefore('=').trim() to it.substringAfter('=').trim() }
        val cookiesAlreadyInstalled = cookies.all { cookie ->
            currentCookies[cookie.substringBefore('=').trim()] == cookie.substringAfter('=').trim()
        }
        if (cookiesAlreadyInstalled) {
            dispatch(onComplete)
            return
        }
        val install = { installLegacyCookies(cookies, manager, onComplete) }
        if (Looper.myLooper() == Looper.getMainLooper()) install()
        else Handler(Looper.getMainLooper()).post(install)
    }

    private fun installLegacyCookies(
        cookies: List<String>,
        manager: CookieManager,
        onComplete: () -> Unit
    ) {
        val remaining = AtomicInteger(cookies.size)
        cookies.forEach { cookie ->
            val name = cookie.substringBefore('=').trim()
            val httpOnly = if (name == "SESSION") "; HttpOnly" else ""
            val secure = if (PortalConfig.SESSION_SCOPE.startsWith("https://")) "; Secure" else ""
            manager.setCookie(
                PortalConfig.SESSION_SCOPE,
                "$cookie; Path=${PortalConfig.SESSION_PATH}$secure$httpOnly; SameSite=Lax"
            ) {
                if (remaining.decrementAndGet() == 0) {
                    manager.flush()
                    onComplete()
                }
            }
        }
    }

    private fun dispatch(onComplete: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) onComplete()
        else Handler(Looper.getMainLooper()).post(onComplete)
    }

    private fun PersistedCookie.installUrl(): String =
        "https://$domain${path.ifEmpty { "/" }}"

    private fun PersistedCookie.toSetCookieValue(): String = buildString {
        append("$name=$value")
        append("; Path=").append(path.ifEmpty { "/" })
        if (!hostOnly) append("; Domain=").append(domain)
        if (secure) append("; Secure")
        if (httpOnly) append("; HttpOnly")
        if (expiresAt != Long.MAX_VALUE) {
            append("; Expires=").append(httpDate(expiresAt))
        }
        append("; SameSite=Lax")
    }

    private val httpDateFormat: java.text.DateFormat by lazy {
        java.text.SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", java.util.Locale.US).apply {
            timeZone = java.util.TimeZone.getTimeZone("GMT")
        }
    }

    private fun httpDate(epochMillis: Long): String =
        httpDateFormat.format(java.util.Date(epochMillis))

    suspend fun restoreToWebViewAndWait(): Boolean = withContext(Dispatchers.Main.immediate) {
        suspendCancellableCoroutine { continuation ->
            val started = restoreToWebView {
                if (continuation.isActive) continuation.resume(true)
            }
            if (!started && continuation.isActive) continuation.resume(false)
        }
    }

    // endregion

    // region 从 WebView 捕获

    /**
     * 抓取 WebView 中当前学校各主机的 cookie。CookieManager 只暴露 name=value，不含
     * path/属性，因此抓到的记录按 host + Path=/ 落库；若登录阶段（OkHttp，含完整属性）已存
     * 在同主机同名 cookie，则保留旧记录的精确 path，避免降级。
     *
     * @param acceptedCookieNames 空列表表示接受任意 cookie（用于非 SESSION 命名的门户）。
     */
    @Synchronized
    fun captureFromWebView(
        cookieHosts: List<String> = emptyList(),
        acceptedCookieNames: List<String> = listOf("SESSION")
    ): Boolean {
        if (!::appContext.isInitialized) return false
        val definition = SchoolAdapterRepository.activeDefinitionOrNull()
        val hosts = cookieHosts.ifEmpty {
            definition?.auth?.sessionCookieHosts?.ifEmpty { null }
                ?: listOfNotNull(runCatching { java.net.URI(PortalConfig.BASE).host }.getOrNull())
        }
        val names = acceptedCookieNames.ifEmpty {
            definition?.auth?.sessionCookieNames ?: acceptedCookieNames
        }.map { it.lowercase() }

        val manager = CookieManager.getInstance()
        val captured = hosts.asSequence()
            .map { host -> host.lowercase() to manager.getCookie("https://$host/").orEmpty() }
            .filter { it.second.isNotBlank() }
            .flatMap { (host, header) ->
                header.split(';').asSequence().map(String::trim).filter { it.contains('=') }.map { pair ->
                    val name = pair.substringBefore('=').trim()
                    val value = pair.substringAfter('=').trim()
                    PersistedCookie(
                        name = name,
                        value = value,
                        domain = host,
                        path = "/",
                        secure = true,
                        // CookieManager 不暴露 HttpOnly；仅对传统 SESSION 名沿用旧启发式。
                        httpOnly = name.equals("SESSION", ignoreCase = true),
                        hostOnly = true,
                        expiresAt = Long.MAX_VALUE
                    )
                }
            }
            .filter { it.value.isNotBlank() }
            .toList()
        if (captured.isEmpty()) return false
        val accepted = names.isEmpty() || captured.any { cookie ->
            names.any { it == cookie.name.lowercase() }
        }
        if (!accepted) return false

        val existing = persistedCookies()
        // 已存在同主机同名记录（登录时保存，path 精确）时保留原属性，仅在值变化时更新值。
        val merged = LinkedHashMap<String, PersistedCookie>()
        existing.forEach { merged[recordKey(it)] = it }
        captured.forEach { cookie ->
            val owner = existing.firstOrNull {
                it.domain.equals(cookie.domain, ignoreCase = true) &&
                    it.name.equals(cookie.name, ignoreCase = true)
            }
            if (owner == null) {
                merged[recordKey(cookie)] = cookie
            } else if (owner.value != cookie.value) {
                merged[recordKey(owner)] = owner.copy(value = cookie.value)
            }
        }
        saveCookies(merged.values.toList())
        return true
    }

    // endregion

    fun clear() {
        if (!::appContext.isInitialized) return
        prefs.edit()
            .remove(KEY_COOKIE_HEADER)
            .remove(KEY_COOKIE_RECORDS)
            .commit()
    }
}

class PalmAcademicApplication : Application() {
    private val backgroundScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    override fun onCreate() {
        super.onCreate()
        PortalThemePreferences.initialize(this)
        SchoolAdapterRepository.initialize(this)
        PortalSessionStore.initialize(this)
        PortalSessionCoordinator.initialize(this)
        // Parse the selected school definition away from the launch activity. HomeActivity can
        // then obtain the already cached definition during its first composition instead of
        // doing asset JSON work on the UI thread.
        backgroundScope.launch(Dispatchers.IO) {
            runCatching { SchoolAdapterRepository.load(this@PalmAcademicApplication) }
        }
        backgroundScope.launch {
            PortalMonitor.restore(this@PalmAcademicApplication)
        }
    }
}
