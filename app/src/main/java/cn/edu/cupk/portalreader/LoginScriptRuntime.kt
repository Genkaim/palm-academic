package cn.edu.cupk.portalreader

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.webkit.WebView
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.FormBody
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * 学校登录脚本沙箱运行时。
 *
 * 安全模型（与 iOS JSContext 实现保持一致，务必同步修改）：
 *  - 适配器 JS 运行在 about:blank 的离屏 WebView 中，页面自身网络被完全关闭
 *    （setBlockNetworkLoads），无 DOM 存储 / 文件 / 内容访问，没有任何环境能力。
 *  - 唯一对外通道是 PalmAcademicHost 桥；http 请求只能发往学校白名单主机的 https，
 *    即使脚本恶意也无法把数据发到学校域以外。
 *  - 会话 cookie 由原生独立 jar 持有，永远不回传给 JS。
 *  - 密码不进入 JS：JS 只能持有占位符 [PASSWORD_TOKEN]，在 http/crypto 边界由原生替换。
 */
@SuppressLint("SetJavaScriptEnabled", "JavascriptInterface")
class LoginScriptRuntime(
    context: Context,
    private val adapterScript: String,
    private val allowedHosts: Set<String>,
    private val sessionCookieNames: List<String>,
    private val successUrlPrefixes: List<String>,
    private val loginUrl: String?,
    private val uiListener: (LoginUiEvent) -> Unit
) {
    private val appContext = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val random = SecureRandom()

    /** 单次登录专用 cookie 罐：与全局 WebView 完全隔离，成功后才持久化。 */
    internal val cookieJar = LoginCookieJar()
    private val httpClient: OkHttpClient =
        PortalHttp.client.newBuilder().cookieJar(cookieJar).build()

    private lateinit var webView: WebView
    private val boot = CompletableDeferred<Unit>()
    private val adapterCalls = java.util.concurrent.ConcurrentHashMap<Int, CompletableDeferred<String>>()
    private val callLock = Mutex()
    @Volatile private var closed = false
    @Volatile private var password: String = ""
    @Volatile private var lastFinalUrl: String = ""

    // ---- 对外数据模型（describe() 返回值） ----

    data class Field(
        val id: String,
        val type: String, // text|password|tel|captcha|smsCode
        val label: String,
        val placeholder: String,
        val required: Boolean,
        val captchaImageUrl: String?,
        val captchaRefreshParam: String?
    )

    data class Checkbox(
        val id: String,
        val label: String,
        val defaultChecked: Boolean,
        val scope: String // local（App 本地行为，不提交）| request（作为变量提交）
    )

    data class Method(
        val id: String,
        val kind: String, // password|sms|qrcode
        val label: String,
        val isDefault: Boolean,
        val fields: List<Field>,
        val checkboxes: List<Checkbox>
    )

    data class Schema(val methods: List<Method>)

    data class SubmitResult(
        val ok: Boolean,
        val kind: String,
        val message: String,
        /** kind=="captcha" 时由脚本提供的动态验证码图片地址（页面非常驻验证码字段）。 */
        val captchaUrl: String?,
        val captchaRefreshParam: String?
    )

    // ---- 生命周期 ----

    suspend fun start() {
        suspendCancellableCoroutine<Unit> { cont ->
            main.post {
                val view = WebView(appContext)
                with(view.settings) {
                    javaScriptEnabled = true
                    domStorageEnabled = false
                    databaseEnabled = false
                    allowFileAccess = false
                    allowContentAccess = false
                    blockNetworkLoads = true
                    blockNetworkImage = true
                    javaScriptCanOpenWindowsAutomatically = false
                    setSupportMultipleWindows(false)
                }
                // 注意：原生桥刻意命名为 __PaNative 而非 PalmAcademicHost。
                // 同一个 .js 文件既包含页面重绘适配器（其入口在检测到
                // window.PalmAcademicHost 时才运行），也包含登录适配器。沙箱不提供
                // PalmAcademicHost，重绘段会自行早退，只暴露 PalmAcademicLoginAdapter。
                view.addJavascriptInterface(HostBridge(), "__PaNative")
                view.webViewClient = object : android.webkit.WebViewClient() {
                    override fun onPageFinished(view: WebView?, url: String?) {
                        if (!boot.isCompleted) {
                            view?.evaluateJavascript(SHIM + "\n" + adapterScript, null)
                            boot.complete(Unit)
                            if (cont.isActive) cont.resume(Unit)
                        }
                    }
                }
                webView = view
                view.loadDataWithBaseURL(null, "<html><head></head><body></body></html>", "text/html", "utf-8", null)
            }
            cont.invokeOnCancellation { }
        }
        boot.await()
    }

    fun close() {
        closed = true
        runCatching { main.post { runCatching { webView.destroy() } } }
        adapterKeys.forEach { adapterCalls.remove(it)?.cancel() }
    }

    private val adapterKeys get() = adapterCalls.keys().toList()

    // ---- 适配器调用 ----

    suspend fun describe(): Schema {
        val raw = callAdapter("describe", JSONObject())
        val json = JSONObject(raw)
        val arr = json.optJSONArray("methods") ?: error("登录脚本缺少 methods")
        val methods = (0 until arr.length()).map { i ->
            val m = arr.getJSONObject(i)
            val fields = m.optJSONArray("fields")?.let { fa ->
                (0 until fa.length()).map { j ->
                    val f = fa.getJSONObject(j)
                    val cap = f.optJSONObject("captcha")
                    Field(
                        id = f.getString("id"),
                        type = f.optString("type", "text"),
                        label = f.optString("label", f.getString("id")),
                        placeholder = f.optString("placeholder", ""),
                        required = f.optBoolean("required", true),
                        captchaImageUrl = cap?.optString("url")?.takeIf { it.isNotBlank() },
                        captchaRefreshParam = cap?.optString("refreshParam")?.takeIf { it.isNotBlank() }
                    )
                }
            }.orEmpty()
            val checks = m.optJSONArray("checkboxes")?.let { ca ->
                (0 until ca.length()).map { j ->
                    val c = ca.getJSONObject(j)
                    Checkbox(
                        id = c.getString("id"),
                        label = c.optString("label", c.getString("id")),
                        defaultChecked = c.optBoolean("defaultChecked", false),
                        scope = c.optString("scope", "request")
                    )
                }
            }.orEmpty()
            Method(
                id = m.getString("id"),
                kind = m.optString("kind", "password"),
                label = m.optString("label", m.getString("id")),
                isDefault = m.optBoolean("default", false),
                fields = fields,
                checkboxes = checks
            )
        }
        require(methods.isNotEmpty()) { "登录脚本未声明任何登录方式" }
        return Schema(methods)
    }

    /**
     * values：可公开字段（账号、图形/短信验证码等）。密码字段在 values 中放占位符
     * [PASSWORD_TOKEN]，真实密码只通过 [secretPassword] 在原生边界短暂持有。
     */
    suspend fun submit(
        methodId: String,
        values: Map<String, String>,
        checkboxes: Map<String, Boolean>,
        secretPassword: String
    ): SubmitResult {
        password = secretPassword
        val raw = callAdapter("submit", methodPayload(methodId, values, checkboxes))
        val json = JSONObject(raw)
        val ok = json.optBoolean("ok", false)
        val kind = json.optString("kind", if (ok) "success" else "rejected")
        val message = json.optString("message", "")
        val cap = json.optJSONObject("captcha")
        val result = SubmitResult(
            ok = ok,
            kind = kind,
            message = message,
            captchaUrl = cap?.optString("url")?.takeIf(String::isNotBlank),
            captchaRefreshParam = cap?.optString("refreshParam")?.takeIf(String::isNotBlank)
        )
        if (ok) verifySession()
        return result
    }

    /** 触发适配器的短信发送动作，返回适配器给的 {ok,message,cooldownSeconds}。 */
    suspend fun sendSms(
        methodId: String,
        values: Map<String, String>,
        checkboxes: Map<String, Boolean>,
        secretPassword: String
    ): JSONObject {
        password = secretPassword
        val raw = callAdapter("sendSms", methodPayload(methodId, values, checkboxes))
        return JSONObject(raw)
    }

    private fun methodPayload(
        methodId: String,
        values: Map<String, String>,
        checkboxes: Map<String, Boolean>
    ): JSONObject = JSONObject()
        .put("methodId", methodId)
        .put("values", JSONObject(values as Map<*, *>))
        .put("checkboxes", JSONObject(checkboxes as Map<*, *>))

    /**
     * 拉取图形验证码。首次取图前先 GET 一次登录页，建立服务端预会话（金智等系统的
     * 验证码依赖会话 cookie），与后续 submit 共用同一个 cookie 罐。
     */
    suspend fun fetchCaptcha(rawUrl: String, refreshParam: String?): ByteArray {
        ensurePrimed()
        var url = substitute(rawUrl).toHttpUrl()
        require(url.scheme == "https" && url.host in allowedHosts) { "验证码地址未授权" }
        if (!refreshParam.isNullOrBlank()) {
            url = url.newBuilder()
                .setQueryParameter(refreshParam, System.currentTimeMillis().toString())
                .build()
        }
        return httpClient.newCall(
            Request.Builder().url(url)
                .header("Referer", loginUrl ?: url.toString())
                .header("Cache-Control", "no-cache")
                .get().build()
        ).execute().use { resp ->
            if (!resp.isSuccessful) error("验证码加载失败（${resp.code}）")
            resp.body?.bytes()?.takeIf(ByteArray::isNotEmpty) ?: error("验证码图片为空")
        }
    }

    private val primedHosts = java.util.Collections.synchronizedSet(HashSet<String>())

    private fun ensurePrimed() {
        val urlString = loginUrl ?: return
        val url = urlString.toHttpUrl()
        if (url.host !in allowedHosts || !primedHosts.add(url.host)) return
        httpClient.newCall(
            Request.Builder().url(url)
                .header("Accept", "text/html,application/xhtml+xml")
                .header("Accept-Language", "zh-CN,zh;q=0.9")
                .get().build()
        ).execute().use { it.body?.close() }
    }

    private fun verifySession() {
        val urlOk = successUrlPrefixes.isEmpty() ||
            successUrlPrefixes.any { lastFinalUrl.startsWith(it) }
        val cookieOk = cookieJar.hasAnyCookie(sessionCookieNames)
        if (!urlOk && !cookieOk) error("登录脚本回报成功，但未建立有效会话")
        cookieJar.persistSession()
    }

    private suspend fun callAdapter(name: String, payload: JSONObject): String {
        val id = nextAdapterId()
        val deferred = CompletableDeferred<String>()
        adapterCalls[id] = deferred
        val payloadJs = JSONObject.quote(payload.toString())
        val script = "javascript:__paCallAdapter($id,${JSONObject.quote(name)},$payloadJs)"
        suspendCancellableCoroutine<Unit> { cont ->
            main.post {
                if (!::webView.isInitialized) {
                    deferred.completeExceptionally(IllegalStateException("登录运行时未初始化"))
                } else {
                    webView.evaluateJavascript(script, null)
                }
                cont.resume(Unit)
            }
            cont.invokeOnCancellation { deferred.cancel() }
        }
        return try {
            deferred.await()
        } finally {
            adapterCalls.remove(id)
        }
    }

    private fun nextAdapterId(): Int {
        while (true) {
            val candidate = ADAPTER_ID.getAndIncrement()
            if (candidate > 0) return candidate
        }
    }

    // ---- JS 桥（方法在 WebView binder 线程调用） ----

    private inner class HostBridge {
        @android.webkit.JavascriptInterface
        fun result(reqId: Int, ok: Boolean, json: String) {
            val d = adapterCalls[reqId] ?: return
            if (ok) d.complete(json) else d.completeExceptionally(IllegalStateException(safeError(json)))
        }

        @android.webkit.JavascriptInterface
        fun hostCall(callId: Int, method: String, argsJson: String) {
            if (closed) {
                rejectCall(callId, "登录已取消"); return
            }
            try {
                val args = JSONObject(argsJson)
                when (method) {
                    "http" -> {
                        val resp = doHttp(args)
                        resolveCall(callId, resp)
                    }
                    "crypto" -> resolveCall(callId, JSONObject().put("value", doCrypto(args)))
                    "sleep" -> {
                        val ms = args.optLong("ms", 0).coerceIn(0, 120_000)
                        Thread.sleep(ms)
                        resolveCall(callId, JSONObject())
                    }
                    "ui" -> {
                        handleUi(args)
                        resolveCall(callId, JSONObject())
                    }
                    else -> rejectCall(callId, "未知能力 $method")
                }
            } catch (t: Throwable) {
                rejectCall(callId, t.message ?: "登录运行时错误")
            }
        }
    }

    private fun resolveCall(callId: Int, json: JSONObject) {
        main.post {
            if (::webView.isInitialized && !closed) {
                webView.evaluateJavascript("__paHostResolve($callId,true,${JSONObject.quote(json.toString())})", null)
            }
        }
    }

    private fun rejectCall(callId: Int, message: String) {
        val payload = JSONObject().put("message", message).toString()
        main.post {
            if (::webView.isInitialized && !closed) {
                webView.evaluateJavascript("__paHostResolve($callId,false,${JSONObject.quote(payload)})", null)
            }
        }
    }

    private fun safeError(json: String): String =
        runCatching { JSONObject(json).optString("message", "登录脚本错误") }.getOrDefault("登录脚本错误")

    // ---- http（限域、秘密替换） ----

    private fun doHttp(args: JSONObject): JSONObject {
        var urlString = substitute(args.optString("url", ""))
        require(urlString.isNotBlank()) { "http.url 为空" }
        var url = urlString.toHttpUrl()
        if (url.scheme == "http" && url.host in allowedHosts) {
            // 仅允许同主机明文跳 https 的自动升级（与引擎/WebView 行为一致）。
            url = url.newBuilder().scheme("https").build()
            urlString = url.toString()
        }
        require(url.scheme == "https") { "登录请求仅允许 https：$urlString" }
        require(url.host in allowedHosts) { "登录脚本试图访问未授权主机：${url.host}" }

        val method = args.optString("method", "GET").uppercase()
        val builder = Request.Builder().url(url)
        val headers = args.optJSONObject("headers")
        if (headers != null) {
            for (key in headers.keys()) {
                builder.header(key, substitute(headers.getString(key)))
            }
        }

        val body: okhttp3.RequestBody? = when {
            args.has("form") -> {
                val form = args.getJSONObject("form")
                val fb = FormBody.Builder()
                for (key in form.keys()) fb.add(key, substitute(form.getString(key)))
                fb.build()
            }
            args.has("json") -> {
                val json = deepSubstitute(args.getJSONObject("json"))
                json.toString().toRequestBody(JSON_MEDIA_TYPE)
            }
            args.has("body") -> substitute(args.getString("body"))
                .toRequestBody("text/plain; charset=utf-8".toMediaType())
            else -> null
        }
        builder.method(method, body)

        httpClient.newCall(builder.build()).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            lastFinalUrl = resp.request.url.toString()
            return JSONObject()
                .put("status", resp.code)
                .put("finalUrl", lastFinalUrl)
                .put("text", text)
        }
    }

    private fun substitute(value: String): String =
        if (password.isNotEmpty() && value.contains(PASSWORD_TOKEN))
            value.replace(PASSWORD_TOKEN, password) else value

    private fun deepSubstitute(json: JSONObject): JSONObject {
        val out = JSONObject()
        for (key in json.keys()) {
            when (val v = json.get(key)) {
                is String -> out.put(key, substitute(v))
                is JSONObject -> out.put(key, deepSubstitute(v))
                is JSONArray -> out.put(key, deepSubstituteArray(v))
                else -> out.put(key, v)
            }
        }
        return out
    }

    private fun deepSubstituteArray(arr: JSONArray): JSONArray {
        val out = JSONArray()
        for (i in 0 until arr.length()) {
            when (val v = arr.get(i)) {
                is String -> out.put(substitute(v))
                is JSONObject -> out.put(deepSubstitute(v))
                is JSONArray -> out.put(deepSubstituteArray(v))
                else -> out.put(v)
            }
        }
        return out
    }

    // ---- crypto（密码仅在边界被替换；明文不回传 JS） ----

    private fun doCrypto(args: JSONObject): String {
        return when (val op = args.optString("op", "")) {
            "sha1" -> sha1(substitute(args.getString("data")))
            "md5" -> md5(substitute(args.getString("data")))
            "rsa-pkcs1" -> rsa(
                substitute(args.getString("data")),
                substitute(args.getString("publicKey"))
            )
            "aes-cbc-pkcs7" -> {
                val key = substitute(args.getString("key")).toByteArray(Charsets.UTF_8)
                val iv = substitute(args.optString("iv", "")).toByteArray(Charsets.UTF_8)
                val prefixLength = args.optInt("prefixLength", 0)
                aesCbc(substitute(args.getString("data")), key, iv, prefixLength)
            }
            else -> error("不支持的加密算法：$op")
        }
    }

    private fun sha1(v: String): String =
        MessageDigest.getInstance("SHA-1").digest(v.toByteArray()).toHex()

    private fun md5(v: String): String =
        MessageDigest.getInstance("MD5").digest(v.toByteArray()).toHex()

    private fun rsa(plain: String, publicKeyBase64: String): String {
        val key = KeyFactory.getInstance("RSA")
            .generatePublic(X509EncodedKeySpec(Base64.decode(publicKeyBase64, Base64.DEFAULT)))
        val cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        return Base64.encodeToString(cipher.doFinal(plain.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
    }

    private fun aesCbc(plain: String, key: ByteArray, iv: ByteArray, prefixLength: Int): String {
        require(key.size in intArrayOf(16, 24, 32)) { "AES key 长度必须为 16/24/32" }
        // 未提供 IV 时原生自生 16 字节随机 IV（对齐金智 encrypt.js 的随机 IV；
        // 密文不携带 IV，首块由随机 64 字符前缀吸收，故 IV 内容对服务端解密无影响）。
        val effectiveIv = if (iv.size == 16) iv else
            randomPrefix(16).toByteArray(Charsets.UTF_8)
        val data = if (prefixLength > 0) randomPrefix(prefixLength) + plain else plain
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(Cipher.ENCRYPT_MODE, javax.crypto.spec.SecretKeySpec(key, "AES"),
            javax.crypto.spec.IvParameterSpec(effectiveIv))
        return Base64.encodeToString(cipher.doFinal(data.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
    }

    private fun randomPrefix(length: Int): String {
        val sb = StringBuilder(length)
        repeat(length) { sb.append(KEYBOARD_CHARS[random.nextInt(KEYBOARD_CHARS.length)]) }
        return sb.toString()
    }

    // ---- UI 事件（二维码等） ----

    private fun handleUi(args: JSONObject) {
        when (args.optString("type", "")) {
            "qr" -> {
                val state = args.optString("state", "waiting")
                val message = args.optString("message", "")
                val bmp: Bitmap? = when {
                    args.has("imageBase64") -> {
                        val bytes = Base64.decode(args.getString("imageBase64"), Base64.DEFAULT)
                        BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                    }
                    args.has("imageUrl") -> fetchBitmap(args.getString("imageUrl"))
                    else -> null
                }
                emit(LoginUiEvent.Qr(state, message, bmp))
            }
            "toast" -> emit(LoginUiEvent.Toast(args.optString("message", "")))
            "state" -> emit(LoginUiEvent.Phase(args.optString("state", ""), args.optString("message", "")))
        }
    }

    private fun fetchBitmap(rawUrl: String): Bitmap? {
        val url = substitute(rawUrl).toHttpUrl()
        require(url.scheme == "https" && url.host in allowedHosts) { "二维码地址未授权" }
        httpClient.newCall(Request.Builder().url(url).get().build()).execute().use { resp ->
            if (!resp.isSuccessful) return null
            val bytes = resp.body?.bytes() ?: return null
            return BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        }
    }

    private fun emit(event: LoginUiEvent) {
        main.post { if (!closed) uiListener(event) }
    }

    companion object {
        const val PASSWORD_TOKEN = "__PA_PASSWORD__"
        const val PASSWORD_FIELD = "password"
        private val ADAPTER_ID = java.util.concurrent.atomic.AtomicInteger(1)
        private val JSON_MEDIA_TYPE = "application/json; charset=utf-8".toMediaType()
        private const val KEYBOARD_CHARS =
            "ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678"

        private fun ByteArray.toHex() = joinToString("") { "%02x".format(it) }

        private val SHIM = """
(function(){
  if (window.__paReady) return; window.__paReady = true;
  var seq = 1, pending = {};
  window.__paHostResolve = function(id, ok, payloadJson){
    var p = pending[id]; if (!p) return; delete pending[id];
    var payload = null;
    try { payload = payloadJson ? JSON.parse(payloadJson) : null; } catch (e) { payload = payloadJson; }
    if (ok) { p.resolve(payload); }
    else { p.reject(new Error((payload && payload.message) || 'login host error')); }
  };
  function hostCall(method, args){
    return new Promise(function(resolve, reject){
      var id = seq++; pending[id] = { resolve: resolve, reject: reject };
      window.__PaNative.hostCall(id, method, JSON.stringify(args || {}));
    });
  }
  window.PalmAcademic = {
    http: function(req){ return hostCall('http', req); },
    crypto: function(spec){ return hostCall('crypto', spec).then(function(r){ return r.value; }); },
    sleep: function(ms){ return hostCall('sleep', { ms: ms }); },
    ui: function(evt){ return hostCall('ui', evt); }
  };
  window.__paCallAdapter = function(reqId, name, payloadJson){
    Promise.resolve().then(function(){
      var A = window.PalmAcademicLoginAdapter;
      if (!A) throw new Error('缺少 PalmAcademicLoginAdapter');
      var fn = A[name];
      if (typeof fn !== 'function') throw new Error('登录脚本缺少方法 ' + name);
      var arg = payloadJson ? JSON.parse(payloadJson) : null;
      return fn.call(A, arg);
    }).then(function(value){
      window.__PaNative.result(reqId, true, JSON.stringify(value === undefined ? null : value));
    }, function(err){
      window.__PaNative.result(reqId, false, JSON.stringify({ message: String((err && err.message) || err) }));
    });
  };
})();
""".trimIndent()
    }
}

sealed class LoginUiEvent {
    data class Qr(val state: String, val message: String, val image: Bitmap?) : LoginUiEvent()
    data class Toast(val message: String) : LoginUiEvent()
    data class Phase(val state: String, val message: String) : LoginUiEvent()
}
