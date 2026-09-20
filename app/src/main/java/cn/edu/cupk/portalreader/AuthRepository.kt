package cn.edu.cupk.portalreader

import android.webkit.CookieManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

class AuthRepository {
    suspend fun login(username: String, password: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            require(username.isNotBlank() && password.isNotBlank()) { "请输入账号和密码" }

            // 盐值、登录和首页验证必须处于同一个连续 HTTP 会话中。首次登录时直接
            // 借用 WebView CookieManager 可能发生异步写入竞争，进而被服务端当作
            // 无效登录并提前触发验证码。
            val loginCookies = LoginCookieJar()
            val loginClient = PortalHttp.client.newBuilder()
                .cookieJar(loginCookies)
                .build()

            // 先打开一次登录页，让服务端下发首次登录所需的预会话 Cookie。
            // 真实教务在没有预会话时可能把正确密码请求误判为异常或要求验证码。
            val loginPageRequest = Request.Builder()
                .url(PortalConfig.LOGIN)
                .header("Referer", PortalConfig.HOME)
                .header("Accept", "text/html,application/xhtml+xml")
                .header("Accept-Language", "zh-CN,zh;q=0.9")
                .get()
                .build()
            loginClient.newCall(loginPageRequest).execute().use { response ->
                response.body?.string()
                if (!response.isSuccessful) error("无法打开教务登录页（${response.code}）")
            }

            val saltRequest = Request.Builder()
                .url("${PortalConfig.BASE}/login-salt")
                .portalAjaxHeaders(PortalConfig.LOGIN)
                .get()
                .build()
            val salt = loginClient.newCall(saltRequest).execute().use { response ->
                if (!response.isSuccessful) error("无法获取登录校验信息（${response.code}）")
                response.body?.string()?.trim()?.trim('"')
                    ?.takeIf { it.isNotEmpty() } ?: error("登录校验信息为空")
            }

            val payload = JSONObject()
                .put("username", username.trim())
                .put("password", sha1("$salt-$password"))
                .put("captchaToken", "")
                .toString()

            val loginRequest = Request.Builder()
                .url(PortalConfig.LOGIN)
                .portalAjaxHeaders(PortalConfig.LOGIN)
                .header("Accept", "application/json")
                .post(payload.toRequestBody("application/json; charset=utf-8".toMediaType()))
                .build()

            loginClient.newCall(loginRequest).execute().use { response ->
                if (!response.isSuccessful) error("登录请求失败（${response.code}）")
                val body = response.body?.string().orEmpty()
                val json = runCatching { JSONObject(body) }.getOrNull()

                // 只有服务端明确给出这两类结果时，才把本次请求判定为凭据失败。
                // 某些部署在登录成功后会返回空响应或 HTML，不能再按 result 缺失
                // 推断为登录失败。
                if (json?.optBoolean("needCaptcha", false) == true) {
                    error("教务系统要求安全验证，请选择下方的网页登录")
                }
                if (json?.has("result") == true && !json.optBoolean("result")) {
                    error(json.optString("message").ifBlank { "账号或密码错误" })
                }
            }

            // 登录接口已经明确受理后直接保存会话。首页结构识别属于内容读取，
            // 不能反过来否定一次已经成功的密码登录。
            if (!loginCookies.hasSessionCookie()) {
                error("登录请求已完成，但没有收到会话信息，请重试")
            }
            loginCookies.persistSession()
            if (!PortalSessionStore.restoreToWebViewAndWait()) {
                error("登录会话未能写入系统 WebView")
            }
        }
    }

    suspend fun validateSession(): SessionValidation = withContext(Dispatchers.IO) {
        if (!PortalHttp.hasSessionCookie()) return@withContext SessionValidation.EXPIRED
        runCatching {
            val request = Request.Builder().url(PortalConfig.HOME).get().build()
            sessionValidationClient.newCall(request).execute().use { response ->
                val html = response.body?.string().orEmpty()
                when {
                    isLoginPage(html, response.request.url.toString()) -> SessionValidation.EXPIRED
                    response.isSuccessful -> SessionValidation.VALID
                    response.code == 401 || response.code == 403 -> SessionValidation.EXPIRED
                    else -> SessionValidation.UNAVAILABLE
                }
            }
        }.getOrDefault(SessionValidation.UNAVAILABLE)
    }

    companion object {
        // Keep session probing short on networks that cannot reach the campus service. Actual
        // page and data requests retain the more tolerant timeout configured in PortalHttp.
        private val sessionValidationClient: OkHttpClient by lazy {
            PortalHttp.client.newBuilder()
                .connectTimeout(8, TimeUnit.SECONDS)
                .readTimeout(10, TimeUnit.SECONDS)
                .callTimeout(12, TimeUnit.SECONDS)
                .build()
        }

        fun isLoginPage(content: String, finalUrl: String = ""): Boolean =
            finalUrl.substringBefore('?').trimEnd('/').endsWith("/login") ||
                content.contains("<title>登入页面</title>") ||
                content.contains("id=\"vue_main\"") && content.contains("login-salt")

        private fun sha1(value: String): String =
            MessageDigest.getInstance("SHA-1")
                .digest(value.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
    }
}

enum class SessionValidation { VALID, EXPIRED, UNAVAILABLE }

private fun Request.Builder.portalAjaxHeaders(referer: String): Request.Builder =
    header("Origin", PortalConfig.ORIGIN)
        .header("Referer", referer)
        .header("X-Requested-With", "XMLHttpRequest")
        .header("Accept-Language", "zh-CN,zh;q=0.9")

private class LoginCookieJar : CookieJar {
    private val cookies = linkedMapOf<String, Cookie>()

    @Synchronized
    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        cookies.forEach { cookie ->
            val key = "${cookie.domain}|${cookie.path}|${cookie.name}"
            if (cookie.expiresAt <= System.currentTimeMillis()) this.cookies.remove(key)
            else this.cookies[key] = cookie
        }
    }

    @Synchronized
    override fun loadForRequest(url: HttpUrl): List<Cookie> =
        cookies.values.filter { it.matches(url) }

    @Synchronized
    fun hasSessionCookie(): Boolean =
        cookies.values.any { it.name == "SESSION" && it.value.isNotBlank() }

    @Synchronized
    fun persistSession() {
        PortalSessionStore.saveCookieHeader(
            cookies.values.joinToString("; ") { cookie -> "${cookie.name}=${cookie.value}" }
        )
    }
}
