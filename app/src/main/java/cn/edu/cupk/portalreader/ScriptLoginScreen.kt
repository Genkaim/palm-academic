package cn.edu.cupk.portalreader

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * type=script 学校的登录控制器：持有离屏沙箱运行时与 schema 驱动的登录状态，
 * 负责账号密码 / 短信 / 扫码三类登录。密码仅在提交边界离开 UI 状态进入原生。
 *
 * 注意：本类不包含任何界面。脚本学校复用既有登录页（RefactoredLoginContent），
 * 只在该页上增量挂载方式切换、短信验证码、二维码面板、验证码挑战/失败弹窗，
 * 不允许另起一套登录页面。
 */
class ScriptLoginController(
    private val appContext: Context,
    private val scope: CoroutineScope,
    private val onAuthenticated: () -> Unit,
    private val onRemember: (username: String, password: String) -> Unit,
    private val onForget: () -> Unit,
    /** 钥匙串/Keystore 中已保存凭证的回填值（如 username/password），仅在 schema 含同名字段时生效。 */
    private val prefillValues: Map<String, String> = emptyMap()
) {
    var phase by mutableStateOf(Phase.LOADING)
        private set
    var initError by mutableStateOf<String?>(null)
        private set
    var methods by mutableStateOf<List<LoginScriptRuntime.Method>>(emptyList())
        private set
    /** 脚本显式声明 methodSwitch:true 时才允许显示方式切换菜单。 */
    var methodSwitch by mutableStateOf(false)
        private set
    var methodId by mutableStateOf("")
        private set
    var busy by mutableStateOf(false)
        private set
    var status by mutableStateOf<String?>(null)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    var qrImage by mutableStateOf<Bitmap?>(null)
        private set
    var qrState by mutableStateOf("")
        private set
    var qrMessage by mutableStateOf("")
        private set

    /** 密码登录被要求输入验证码时弹出的挑战框（null=不显示）。 */
    var captchaChallenge by mutableStateOf<CaptchaChallenge?>(null)
        private set
    var captchaDialogInput by mutableStateOf("")
        private set
    var captchaDialogImage by mutableStateOf<ByteArray?>(null)
        private set
    /** 短信/扫码等方式登录失败时的模态弹窗消息（null=不显示）。 */
    var failureDialog by mutableStateOf<String?>(null)
        private set

    data class CaptchaChallenge(
        val imageUrl: String,
        val refreshParam: String?,
        /** 确认后验证码写入的字段键（固定字段 id 或动态 "captcha"）。 */
        val targetKey: String
    )

    val values = mutableStateMapOf<String, String>()
    val checkboxes = mutableStateMapOf<String, Boolean>()
    val captchaImages = mutableStateMapOf<String, ByteArray>()
    var smsCooldown by mutableStateOf(0)
        private set

    private var runtime: LoginScriptRuntime? = null
    private var submitJob: Job? = null
    private var cooldownJob: Job? = null

    enum class Phase { LOADING, READY }

    fun start(definition: SchoolDefinition) {
        phase = Phase.LOADING
        initError = null
        val auth = definition.auth
        val scriptPath = auth.loginScript ?: definition.adapterAsset
        val script = SchoolAdapterRepository.readLoginScript(appContext, scriptPath)
        val rt = LoginScriptRuntime(
            context = appContext,
            adapterScript = script,
            allowedHosts = auth.allowedHosts(definition.baseUrl),
            sessionCookieNames = auth.sessionCookieNames,
            successUrlPrefixes = auth.successUrlPrefixes,
            loginUrl = auth.loginUrl
        ) { event -> applyUiEvent(event) }
        runtime = rt
        scope.launch {
            runCatching {
                rt.start()
                val schema = rt.describe()
                methods = schema.methods
                methodSwitch = schema.methodSwitch
                val default = schema.methods.firstOrNull { it.isDefault } ?: schema.methods.first()
                bindMethod(default)
                phase = Phase.READY
                if (default.kind == "qrcode") launchQr(default)
            }.onFailure {
                initError = it.message ?: "登录脚本初始化失败"
                phase = Phase.READY
            }
        }
    }

    fun close() {
        submitJob?.cancel()
        cooldownJob?.cancel()
        runtime?.close()
        runtime = null
    }

    fun currentMethod(): LoginScriptRuntime.Method? =
        methods.firstOrNull { it.id == methodId }

    fun selectMethod(method: LoginScriptRuntime.Method) {
        if (!methodSwitch || method.id == methodId) return
        submitJob?.cancel()
        busy = false
        error = null
        status = null
        bindMethod(method)
        if (method.kind == "qrcode") launchQr(method)
    }

    private fun bindMethod(method: LoginScriptRuntime.Method) {
        methodId = method.id
        // 切方法时清掉非通用字段（保留账号便于跨方式复用）。
        val keepUsername = values["username"].orEmpty()
        values.clear()
        if (keepUsername.isNotEmpty()) values["username"] = keepUsername
        method.fields.forEach { field ->
            if (field.type == "captcha") values[field.id] = ""
        }
        // 回填已保存凭证：仅写入当前方式确实存在的字段（短信/扫码方式没有 password 字段，
        // 密码不会跨方式泄漏到提交值里）。验证码等已被置空的字段不覆盖。
        prefillValues.forEach { (key, saved) ->
            if (saved.isNotEmpty() && method.fields.any { it.id == key } && values[key] == null) {
                values[key] = saved
            }
        }
        checkboxes.clear()
        method.checkboxes.forEach { checkboxes[it.id] = it.defaultChecked }
        qrImage = null; qrState = ""; qrMessage = ""
        captchaChallenge = null; captchaDialogInput = ""; captchaDialogImage = null
        method.fields.filter { it.type == "captcha" }.forEach { refreshCaptcha(it) }
    }

    fun setValue(id: String, value: String) { values[id] = value }
    fun toggleCheckbox(id: String) { checkboxes[id] = !checkboxes.getOrDefault(id, false) }

    fun refreshCaptcha(field: LoginScriptRuntime.Field) {
        val url = field.captchaImageUrl ?: return
        scope.launch {
            runCatching { runtime?.fetchCaptcha(url, field.captchaRefreshParam) }
                .onSuccess { if (it != null) captchaImages[field.id] = it }
                .onFailure { captchaImages.remove(field.id) }
        }
    }

    fun sendSms(codeField: LoginScriptRuntime.Field) {
        val method = currentMethod() ?: return
        if (smsCooldown > 0 || busy) return
        scope.launch {
            busy = true; error = null; status = "正在发送短信验证码…"
            runCatching {
                runtime!!.sendSms(method.id, publicValues(), checkboxes.toMap(), secretPassword())
            }.onSuccess { json ->
                busy = false; status = null
                if (json.optBoolean("ok", false)) {
                    val seconds = json.optInt("cooldownSeconds", 60).coerceAtLeast(1)
                    startCooldown(seconds)
                    json.optString("message").takeIf(String::isNotBlank)?.let { status = it }
                } else {
                    error = json.optString("message", "短信发送失败")
                    method.fields.firstOrNull { it.type == "captcha" }?.let(::refreshCaptcha)
                }
            }.onFailure {
                busy = false; status = null
                error = it.message ?: "网络异常，短信未发送"
            }
        }
    }

    private fun startCooldown(seconds: Int) {
        cooldownJob?.cancel()
        smsCooldown = seconds
        cooldownJob = scope.launch {
            while (smsCooldown > 0) { delay(1000); smsCooldown -= 1 }
        }
    }

    fun submit() {
        val method = currentMethod() ?: return
        if (busy) return
        val missing = method.fields.firstOrNull { it.required && values[it.id].isNullOrBlank() }
        if (missing != null) { error = "请输入${missing.label}"; return }
        submitJob?.cancel()
        submitJob = scope.launch {
            var attempt = 0
            while (true) {
                busy = true; error = null
                status = when {
                    attempt == 0 -> "正在登录…"
                    method.kind == "password" -> "登录未成功，正在重试（第 $attempt 次）…"
                    else -> "网络不稳定，正在重试（第 $attempt 次）…"
                }
                val result = runCatching {
                    runtime!!.submit(method.id, publicValues(), checkboxes.toMap(), secretPassword())
                }
                busy = false; status = null
                result.onSuccess { r ->
                    if (r.ok) { persistAndFinish(); return@launch }
                    handleDefinitiveFailure(method, r)
                    return@launch
                }.onFailure {
                    // 网络类异常对所有方式都持续重试，不打断用户。
                    attempt += 1
                    delay(1000L shl minOf(attempt - 1, 4))
                }
            }
        }
    }

    /**
     * 统一登录失败策略：
     *  - 密码登录、该方式含图形验证码（或适配器要求验证码）：弹出验证码挑战框；
     *  - 密码登录、无验证码：不弹窗，直接重新走 submit（由调用循环持续重试）；
     *  - 短信/扫码等其它方式：弹“登录失败”模态框。
     */
    private fun handleDefinitiveFailure(
        method: LoginScriptRuntime.Method,
        r: LoginScriptRuntime.SubmitResult
    ) {
        if (method.kind != "password") {
            failureDialog = r.message.ifBlank { "登录失败，请检查后重试" }
            return
        }
        // 优先使用脚本在需要验证码时动态给出的验证码图片地址。
        if (r.kind == "captcha" && !r.captchaUrl.isNullOrBlank()) {
            openCaptchaChallenge(r.captchaUrl, r.captchaRefreshParam, "captcha")
            return
        }
        // 其次使用该方式声明的常驻图形验证码字段。
        val field = method.fields.firstOrNull { it.type == "captcha" }
        if (field != null && !field.captchaImageUrl.isNullOrBlank()) {
            openCaptchaChallenge(field.captchaImageUrl, field.captchaRefreshParam, field.id)
            return
        }
        // 无验证码密码登录：直接重试。
        submit()
    }

    private fun openCaptchaChallenge(imageUrl: String, refreshParam: String?, targetKey: String) {
        captchaDialogInput = values[targetKey].orEmpty()
        captchaDialogImage = null
        captchaChallenge = CaptchaChallenge(imageUrl, refreshParam, targetKey)
        refreshDialogCaptcha()
    }

    fun refreshDialogCaptcha() {
        val challenge = captchaChallenge ?: return
        scope.launch {
            runCatching { runtime?.fetchCaptcha(challenge.imageUrl, challenge.refreshParam) }
                .onSuccess { captchaDialogImage = it }
                .onFailure { captchaDialogImage = null }
        }
    }

    fun typeCaptchaInput(value: String) { captchaDialogInput = value }

    fun confirmCaptchaDialog() {
        val challenge = captchaChallenge ?: return
        if (captchaDialogInput.isBlank()) return
        values[challenge.targetKey] = captchaDialogInput
        captchaChallenge = null
        captchaDialogInput = ""
        captchaDialogImage = null
        submit()
    }

    fun dismissCaptchaDialog() {
        captchaChallenge = null
        captchaDialogInput = ""
        captchaDialogImage = null
    }

    fun retryAfterFailure() {
        failureDialog = null
        val method = currentMethod() ?: return
        if (method.kind == "qrcode") launchQr(method) else submit()
    }

    fun dismissFailure() { failureDialog = null }

    private fun launchQr(method: LoginScriptRuntime.Method) {
        submitJob?.cancel()
        submitJob = scope.launch {
            var attempt = 0
            while (true) {
                busy = true; error = null
                status = if (attempt == 0) "正在生成二维码…" else "网络不稳定，正在重试（第 $attempt 次）…"
                val result = runCatching {
                    runtime!!.submit(method.id, emptyMap(), checkboxes.toMap(), "")
                }
                busy = false; status = null
                result.onSuccess { r ->
                    if (r.ok) { persistAndFinish(); return@launch }
                    failureDialog = r.message.ifBlank { "二维码登录失败，请重试" }
                    return@launch
                }.onFailure {
                    attempt += 1
                    delay(1000L shl minOf(attempt - 1, 4))
                }
            }
        }
    }

    private fun applyUiEvent(event: LoginUiEvent) {
        when (event) {
            is LoginUiEvent.Qr -> {
                qrState = event.state
                qrMessage = event.message
                event.image?.let { qrImage = it }
            }
            is LoginUiEvent.Toast -> { status = event.message }
            is LoginUiEvent.Phase -> { qrState = event.state; qrMessage = event.message }
        }
    }

    /** 密码字段用占位符替换后再交给运行时；真实密码单独走 secret 通道。 */
    private fun publicValues(): Map<String, String> {
        val method = currentMethod() ?: return values.toMap()
        return values.mapValues { (key, value) ->
            if (method.fields.any { it.id == key && it.type == "password" })
                LoginScriptRuntime.PASSWORD_TOKEN else value
        }
    }

    private fun secretPassword(): String =
        currentMethod()?.fields
            ?.firstOrNull { it.type == "password" }
            ?.let { values[it.id].orEmpty() }
            .orEmpty()

    private fun persistAndFinish() {
        scope.launch {
            status = "正在进入…"
            val ok = runCatching { PortalSessionStore.restoreToWebViewAndWait() }.getOrDefault(false)
            if (!ok) { error = "登录会话未能写入系统 WebView"; busy = false; status = null; return@launch }
            // local/request 作用域的“记住账号/密码”复选框，id 统一为 rememberCredential。
            val remember = checkboxes.getOrDefault("rememberCredential", false)
            val username = values["username"].orEmpty()
            if (remember && username.isNotBlank()) onRemember(username, secretPassword()) else onForget()
            busy = false; status = null
            onAuthenticated()
        }
    }
}
