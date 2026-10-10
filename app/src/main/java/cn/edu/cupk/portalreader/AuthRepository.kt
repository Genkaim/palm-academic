package cn.edu.cupk.portalreader

import android.util.Base64
import android.webkit.CookieManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.FormBody
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.spec.X509EncodedKeySpec
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher

/**
 * The portal answered the password handshake with a DEFINITIVE rejection: wrong credentials or a
 * captcha/security challenge. Only this kind of failure may bounce the user back to the login
 * form. Every other failure (timeouts, dropped connections, 5xx, missing follow-up cookies on a
 * slow network) is a network problem and the caller must keep retrying instead of showing an
 * error.
 */
class LoginRejectedException(message: String) : IllegalStateException(message)

class AuthRepository {
    private data class PreparedLogin(val cookies: LoginCookieJar, val client: OkHttpClient)
    @Volatile private var preparedLogin: PreparedLogin? = null

    suspend fun refreshCaptcha(): Result<ByteArray> = withContext(Dispatchers.IO) {
        runCatching {
            val auth = SchoolAdapterRepository.activeDefinitionOrNull()?.auth
                ?: error("学校配置缺少登录信息")
            val captcha = auth.captcha
            require(captcha.required && !captcha.imageUrl.isNullOrBlank()) { "当前学校没有配置验证码图片" }

            val cookies = LoginCookieJar()
            val client = PortalHttp.client.newBuilder().cookieJar(cookies).build()
            val loginUrl = auth.loginUrl ?: PortalConfig.LOGIN
            client.newCall(
                Request.Builder()
                    .url(loginUrl)
                    .header("Accept", "text/html,application/xhtml+xml")
                    .header("Accept-Language", "zh-CN,zh;q=0.9")
                    .get()
                    .build()
            ).execute().use { response ->
                response.body?.close()
                if (!response.isSuccessful) error("无法打开登录页（${response.code}）")
            }
            val imageUrl = captcha.imageUrl.toHttpUrl().newBuilder()
                .apply {
                    captcha.refreshQueryParameter.takeIf(String::isNotBlank)?.let { key ->
                        removeAllQueryParameters(key)
                        addQueryParameter(key, System.currentTimeMillis().toString())
                    }
                }
                .build()
            val bytes = client.newCall(
                Request.Builder()
                    .url(imageUrl)
                    .header("Referer", loginUrl)
                    .header("Cache-Control", "no-cache")
                    .get()
                    .build()
            ).execute().use { response ->
                if (!response.isSuccessful) error("验证码加载失败（${response.code}）")
                response.body?.bytes()?.takeIf(ByteArray::isNotEmpty) ?: error("验证码图片为空")
            }
            preparedLogin = PreparedLogin(cookies, client)
            bytes
        }
    }

    fun discardPreparedLogin() {
        preparedLogin = null
    }

    suspend fun login(
        username: String,
        password: String,
        captcha: String = ""
    ): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            require(username.isNotBlank() && password.isNotBlank()) { "请输入账号和密码" }

            val auth = SchoolAdapterRepository.activeDefinitionOrNull()?.auth
            if (auth?.captcha?.required == true && captcha.isBlank()) {
                throw LoginRejectedException("请输入验证码")
            }

            // 盐值、登录和首页验证必须处于同一个连续 HTTP 会话中。首次登录时直接
            // 借用 WebView CookieManager 可能发生异步写入竞争，进而被服务端当作
            // 无效登录并提前触发验证码。
            val context = if (auth?.captcha?.required == true) preparedLogin else null
            val loginCookies = context?.cookies ?: LoginCookieJar()
            val loginClient = context?.client ?: PortalHttp.client.newBuilder()
                .cookieJar(loginCookies).build()

            // 通用登录引擎：学校定义自己描述整个握手（请求/提取/加密/判定），App 只负责执行。
            // 内置的 salted-sha1 流程本质上是引擎的一条具体配置。
            if (auth?.usesEngine == true) {
                loginWithEngine(username.trim(), password, captcha, auth, loginCookies, loginClient)
                loginCookies.persistSession()
                if (!PortalSessionStore.restoreToWebViewAndWait()) {
                    error("登录会话未能写入系统 WebView")
                }
                discardPreparedLogin()
                return@runCatching
            }

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
                .put("captchaToken", captcha)
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

                // 只有服务端明确给出这两类结果时，才把本次请求判定为凭据失败（终态，
                // 不再重试）。某些部署在登录成功后会返回空响应或 HTML，不能再按
                // result 缺失推断为登录失败；那类情况落入下面的网络/会话类错误，
                // 由调用方持续重试。
                if (json?.optBoolean("needCaptcha", false) == true) {
                    throw LoginRejectedException("教务系统要求安全验证，请选择下方的网页登录")
                }
                if (json?.has("result") == true && !json.optBoolean("result")) {
                    throw LoginRejectedException(
                        json.optString("message").ifBlank { "账号或密码错误" }
                    )
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
            discardPreparedLogin()
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

    /**
     * 通用登录引擎：按学校定义依次执行 request/extract/transform 步骤，
     * 最后根据 outcome 判定登录结果。步骤内的网络异常原样抛出，由调用方按
     * "网络问题持续重试"的约定处理；只有命中 captcha/rejected 规则时才抛出
     * LoginRejectedException 把用户打回登录页。
     */
    private fun loginWithEngine(
        username: String,
        password: String,
        captcha: String,
        auth: PortalAuthDefinition,
        loginCookies: LoginCookieJar,
        loginClient: OkHttpClient
    ) {
        val engine = auth.engine ?: error("学校定义缺少登录引擎配置")
        val variables = mutableMapOf(
            "username" to username,
            "password" to password,
            "captcha" to captcha,
            "baseUrl" to (SchoolAdapterRepository.activeDefinitionOrNull()?.baseUrl.orEmpty()),
            "loginUrl" to (auth.loginUrl.orEmpty())
        )
        val stepResponses = mutableMapOf<String, EngineResponse>()
        var lastResponse: EngineResponse? = null

        val steps = engine.getJSONArray("steps")
        for (index in 0 until steps.length()) {
            val step = steps.getJSONObject(index)
            val id = step.optString("id").ifBlank { "step$index" }
            when {
                step.has("request") -> {
                    val response = executeEngineRequest(
                        step.getJSONObject("request"), variables, loginClient
                    )
                    stepResponses[id] = response
                    lastResponse = response
                }
                step.has("extract") -> {
                    val extract = step.getJSONObject("extract")
                    val fromId = extract.optString("from").ifBlank { null }
                    val source = when {
                        fromId != null -> stepResponses[fromId]
                            ?: error("提取步骤 '$id' 引用了不存在的请求步骤 '$fromId'")
                        else -> lastResponse ?: error("提取步骤 '$id' 之前没有任何请求步骤")
                    }
                    val regex = Regex(
                        extract.getString("regex"),
                        setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE)
                    )
                    variables[id] = regex.find(source.body)
                        ?.groupValues?.getOrNull(extract.optInt("group", 1))
                        ?: error("提取步骤 '$id' 未匹配到内容")
                }
                step.has("transform") -> {
                    val transform = step.getJSONObject("transform")
                    val input = interpolate(transform.optString("input"), variables)
                    variables[id] = when (val algorithm = transform.getString("algorithm")) {
                        "rsa-pkcs1-base64" -> rsaEncryptBase64(input, transform.getString("publicKey"))
                        "sha1" -> sha1(input)
                        "md5" -> md5(input)
                        else -> error("不支持的变换算法: $algorithm")
                    }
                }
                else -> error("引擎步骤 '$id' 必须包含 request/extract/transform 之一")
            }
        }

        judgeEngineOutcome(engine.optJSONObject("outcome"), lastResponse, auth, loginCookies)
    }

    private fun executeEngineRequest(
        spec: JSONObject,
        variables: Map<String, String>,
        loginClient: OkHttpClient
    ): EngineResponse {
        val method = spec.optString("method", "GET").uppercase()
        val builder = Request.Builder().url(interpolate(spec.getString("url"), variables))
        spec.optJSONObject("headers")?.let { headers ->
            for (key in headers.keys()) {
                builder.header(key, interpolate(headers.getString(key), variables))
            }
        }
        when (spec.optString("contentType")) {
            "form" -> {
                val body = FormBody.Builder().also { form ->
                    spec.optJSONObject("form")?.let { fields ->
                        for (key in fields.keys()) {
                            form.add(key, interpolate(fields.getString(key), variables))
                        }
                    }
                }.build()
                builder.method(method, body)
            }
            "json" -> {
                val payload = interpolateJson(spec.optJSONObject("json") ?: JSONObject(), variables)
                builder.method(method, payload.toString().toRequestBody(JSON_MEDIA_TYPE))
            }
            else -> when {
                spec.has("body") ->
                    builder.method(method, interpolate(spec.getString("body"), variables).toRequestBody(null))
                method == "GET" || method == "HEAD" -> builder.method(method, null)
                else -> builder.method(method, ByteArray(0).toRequestBody(null))
            }
        }
        loginClient.newCall(builder.build()).execute().use { response ->
            return EngineResponse(
                code = response.code,
                body = response.body?.string().orEmpty(),
                finalUrl = response.request.url.toString()
            )
        }
    }

    private fun judgeEngineOutcome(
        outcome: JSONObject?,
        lastResponse: EngineResponse?,
        auth: PortalAuthDefinition,
        loginCookies: LoginCookieJar
    ) {
        val response = lastResponse ?: error("登录引擎没有执行任何请求步骤")

        fun matches(rule: JSONObject?): Boolean {
            if (rule == null) return false
            rule.optJSONArray("statusCodes")?.let { codes ->
                if (!(0 until codes.length()).any { codes.getInt(it) == response.code }) return false
            }
            rule.optJSONArray("bodyContains")?.let { needles ->
                if (!(0 until needles.length()).any {
                        response.body.contains(needles.getString(it), ignoreCase = true)
                    }
                ) return false
            }
            return true
        }

        outcome?.optJSONObject("captcha")?.takeIf(::matches)?.let { rule ->
            throw LoginRejectedException(
                rule.optString("message").ifBlank { "教务系统要求安全验证，请选择下方的网页登录" }
            )
        }
        outcome?.optJSONObject("rejected")?.takeIf(::matches)?.let { rule ->
            throw LoginRejectedException(
                rule.optString("message").ifBlank { "账号或密码错误" }
            )
        }

        val success = outcome?.optJSONObject("success")
        val urlPrefixes = success?.optJSONArray("finalUrlPrefixes")?.toStringList()
            ?: auth.successUrlPrefixes
        val cookieNames = success?.optJSONArray("cookies")?.toStringList()
            ?: auth.sessionCookieNames
        val statusCodes = success?.optJSONArray("statusCodes")?.let { codes ->
            (0 until codes.length()).map { codes.getInt(it) }
        }.orEmpty()

        val urlOk = urlPrefixes.isEmpty() || urlPrefixes.any { response.finalUrl.startsWith(it) }
        val cookiesOk = loginCookies.hasAnyCookie(cookieNames)
        val statusOk = statusCodes.isEmpty() || response.code in statusCodes
        if (!urlOk || !cookiesOk || !statusOk) {
            error("登录请求已完成，但未确认登录成功，请重试")
        }
    }

    private fun interpolate(template: String, variables: Map<String, String>): String {
        var result = template
        for ((key, value) in variables) {
            result = result.replace("{$key}", value)
        }
        return result
    }

    private fun interpolateJson(json: JSONObject, variables: Map<String, String>): JSONObject {
        val result = JSONObject()
        for (key in json.keys()) {
            val value = json.get(key)
            result.put(key, if (value is String) interpolate(value, variables) else value)
        }
        return result
    }

    private fun JSONArray.toStringList(): List<String> =
        (0 until length()).map { getString(it) }

    private data class EngineResponse(
        val code: Int,
        val body: String,
        val finalUrl: String
    )

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

        private val JSON_MEDIA_TYPE = "application/json; charset=utf-8".toMediaType()

        private fun sha1(value: String): String =
            MessageDigest.getInstance("SHA-1")
                .digest(value.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }

        private fun md5(value: String): String =
            MessageDigest.getInstance("MD5")
                .digest(value.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }

        private fun rsaEncryptBase64(plain: String, publicKeyBase64: String): String {
            val key = KeyFactory.getInstance("RSA")
                .generatePublic(X509EncodedKeySpec(Base64.decode(publicKeyBase64, Base64.DEFAULT)))
            val cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding")
            cipher.init(Cipher.ENCRYPT_MODE, key)
            return Base64.encodeToString(cipher.doFinal(plain.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
        }
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
    fun hasAnyCookie(names: List<String>): Boolean =
        names.isEmpty() || cookies.values.any { cookie ->
            cookie.value.isNotBlank() && names.any { it.equals(cookie.name, ignoreCase = true) }
        }

    @Synchronized
    fun persistSession() {
        PortalSessionStore.saveCookieHeader(
            cookies.values.joinToString("; ") { cookie -> "${cookie.name}=${cookie.value}" }
        )
    }
}
