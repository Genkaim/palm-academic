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
    /** 密码校验通过后由脚本请求 App 展示的通用多因子认证弹窗。 */
    var mfaChallenge by mutableStateOf<LoginScriptRuntime.Challenge?>(null)
        private set
    var mfaCode by mutableStateOf("")
        private set
    var mfaRemember by mutableStateOf(true)
        private set
    var mfaBusy by mutableStateOf(false)
        private set
    var mfaError by mutableStateOf<String?>(null)
        private set
    var mfaCooldown by mutableStateOf(0)
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
    private var mfaCooldownJob: Job? = null
    private var automaticPasswordSubmitRequested = false

    enum class Phase { LOADING, READY }

    fun start(definition: SchoolDefinition) {
        phase = Phase.LOADING
        initError = null
        val auth = definition.auth
        val scriptPath = auth.loginScript ?: definition.adapterAsset
        val script = SchoolAdapterRepository.readLoginScript(appContext, scriptPath)
        val volatileNames = (auth.sessionCookieNames + listOf("JSESSIONID", "CASTGC"))
            .map(String::uppercase)
            .toSet()
        val initialCookies = PortalSessionStore.persistedCookies().filter { cookie ->
            cookie.name.uppercase() !in volatileNames &&
                !cookie.name.uppercase().contains("TICKET")
        }
        val rt = LoginScriptRuntime(
            context = appContext,
            adapterScript = script,
            allowedHosts = auth.allowedHosts(definition.baseUrl),
            sessionCookieNames = auth.sessionCookieNames,
            successUrlPrefixes = auth.successUrlPrefixes,
            loginUrl = auth.loginUrl,
            initialCookies = initialCookies
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
                if (automaticPasswordSubmitRequested && default.kind == "password") {
                    automaticPasswordSubmitRequested = false
                    submit()
                } else if (default.kind == "qrcode") {
                    launchQr(default)
                }
            }.onFailure {
                initError = it.message ?: "登录脚本初始化失败"
                phase = Phase.READY
            }
        }
    }

    fun close() {
        submitJob?.cancel()
        cooldownJob?.cancel()
        mfaCooldownJob?.cancel()
        runtime?.close()
        runtime = null
    }

    /** Replays saved credentials once so an expired background session opens the native MFA
     * challenge directly instead of making the user press the password-login button again. */
    fun requestAutomaticPasswordSubmit() {
        automaticPasswordSubmitRequested = true
        if (phase == Phase.READY && currentMethod()?.kind == "password") {
            automaticPasswordSubmitRequested = false
            submit()
        }
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
        mfaChallenge = null; mfaCode = ""; mfaError = null; mfaBusy = false
        method.fields.filter { it.type == "captcha" }.forEach { refreshCaptcha(it) }
    }

    fun setValue(id: String, value: String) { values[id] = value }
    fun toggleCheckbox(id: String) { checkboxes[id] = !checkboxes.getOrDefault(id, false) }

    fun refreshCaptcha(field: LoginScriptRuntime.Field) {
        val url = field.captchaImageUrl ?: return
        scope.launch {
            runCatching { runtime?.fetchCaptcha(url, field.captchaRefreshParam) }
                .onSuccess {
                    if (it != null) {
                        captchaImages[field.id] = it
                        error = null
                    }
                }
                .onFailure {
                    captchaImages.remove(field.id)
                    // 给出可见原因，用户可点击尾部图片区域直接重试（UI 本身就是刷新按钮）。
                    error = "图形验证码加载失败，请点击验证码图片重试"
                }
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
            // 密码方式的网络异常无限静默重试（用户无需操作）；短信/扫码是短交互，
            // 持续失败时必须有出口：最多 3 轮后弹“登录失败”，避免界面一直转圈。
            val maxAttempts = if (method.kind == "password") Int.MAX_VALUE else 3
            while (attempt < maxAttempts) {
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
                    attempt += 1
                    if (attempt >= maxAttempts) {
                        failureDialog = "网络异常，登录失败，请重新登录"
                        return@launch
                    }
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
        if (r.kind == "mfa" && r.challenge != null) {
            mfaChallenge = r.challenge
            mfaCode = ""
            mfaRemember = r.challenge.rememberDefault
            mfaError = null
            return
        }
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
        // 密码被明确拒绝属于终态；网络异常由 submit() 的异常分支自动重试。
        error = r.message.ifBlank { "账号或密码错误" }
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

    /**
     * “登录失败”弹窗的“重新登录”：不直接重放旧请求，而是把一次性输入清空、图形验证码
     * 换一张，把用户引导回登录表单重新填写提交（扫码方式则重新生成二维码）。
     */
    fun retryAfterFailure() {
        failureDialog = null
        val method = currentMethod() ?: return
        busy = false; error = null; status = null
        if (method.kind == "qrcode") {
            qrImage = null; qrState = ""; qrMessage = ""
            launchQr(method)
            return
        }
        method.fields.forEach { field ->
            when (field.type) {
                // 图形/短信验证码一次性使用，必须清空并换新；账号保留便于用户直接重试。
                "captcha", "smsCode" -> values[field.id] = ""
            }
        }
        method.fields.filter { it.type == "captcha" }.forEach { refreshCaptcha(it) }
    }

    fun dismissFailure() { failureDialog = null }

    fun typeMfaCode(value: String) { mfaCode = value }

    fun toggleMfaRemember() { mfaRemember = !mfaRemember }

    fun sendMfaCode() {
        val method = currentMethod() ?: return
        val challenge = mfaChallenge ?: return
        if (mfaBusy || mfaCooldown > 0) return
        scope.launch {
            mfaBusy = true
            mfaError = null
            runCatching {
                runtime!!.sendChallenge(
                    method.id,
                    publicValues(),
                    checkboxes.toMap(),
                    challenge.id,
                    secretPassword()
                )
            }.onSuccess { json ->
                mfaBusy = false
                if (json.optBoolean("ok", false)) {
                    val seconds = json.optInt("cooldownSeconds", 60).coerceAtLeast(1)
                    mfaCooldownJob?.cancel()
                    mfaCooldown = seconds
                    mfaCooldownJob = scope.launch {
                        while (mfaCooldown > 0) { delay(1000); mfaCooldown -= 1 }
                    }
                } else {
                    mfaError = json.optString("message", "验证码发送失败")
                }
            }.onFailure {
                mfaBusy = false
                mfaError = it.message ?: "网络异常，验证码未发送"
            }
        }
    }

    fun confirmMfaChallenge() {
        val method = currentMethod() ?: return
        val challenge = mfaChallenge ?: return
        if (mfaBusy || mfaCode.isBlank()) return
        scope.launch {
            mfaBusy = true
            mfaError = null
            runCatching {
                runtime!!.submitChallenge(
                    method.id,
                    publicValues(),
                    checkboxes.toMap(),
                    challenge.id,
                    mfaCode.trim(),
                    mfaRemember,
                    secretPassword()
                )
            }.onSuccess { result ->
                mfaBusy = false
                if (result.ok) {
                    mfaChallenge = null
                    persistAndFinish()
                } else {
                    result.challenge?.let {
                        mfaChallenge = it
                        mfaRemember = mfaRemember || it.rememberDefault
                    }
                    mfaError = result.message.ifBlank { "安全验证码错误，请重试" }
                }
            }.onFailure {
                mfaBusy = false
                mfaError = it.message ?: "安全验证失败，请重试"
            }
        }
    }

    fun dismissMfaChallenge() {
        mfaChallenge = null
        mfaCode = ""
        mfaError = null
        mfaBusy = false
        mfaCooldownJob?.cancel()
        mfaCooldown = 0
    }

    private fun launchQr(method: LoginScriptRuntime.Method) {
        submitJob?.cancel()
        submitJob = scope.launch {
            var attempt = 0
            // JS 内部轮询本身会容错；外层网络整体不可用时最多重启 3 轮，随后弹失败框。
            while (attempt < 3) {
                // 只有首张二维码尚未到达时才显示忙碌提示。submit 内部包含 JS 轮询循环，
                // 会持续到扫码成功/失败，期间不能一直占用 busy，否则切换栏会被永久禁用；
                // 轮询中的状态（已扫码/已刷新/失效）由二维码面板的 qrMessage 展示。
                if (qrImage == null) {
                    busy = true; error = null
                    status = if (attempt == 0) "正在生成二维码…" else "正在重新生成二维码…"
                }
                val result = runCatching {
                    runtime!!.submit(method.id, emptyMap(), checkboxes.toMap(), "")
                }
                busy = false; status = null
                result.onSuccess { r ->
                    if (r.ok) { persistAndFinish(); return@launch }
                    failureDialog = r.message.ifBlank { "二维码登录失败，请重新登录" }
                    return@launch
                }.onFailure {
                    attempt += 1
                    if (attempt >= 3) {
                        failureDialog = "网络异常，二维码登录失败，请重新登录"
                        return@launch
                    }
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
                // 二维码图片一到达就结束“正在生成二维码”提示，不再等整个轮询提交返回。
                event.image?.let {
                    qrImage = it
                    busy = false
                    status = null
                }
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
            // 保存密码关键词只由密码方式维护：勾选则用本次账号密码覆盖旧记录，未勾选则清除；
            // 短信/扫码方式没有密码字段，绝不能顺手删掉已保存的密码（切换方式登录后仍要保留）。
            if (currentMethod()?.kind == "password") {
                val remember = checkboxes.getOrDefault("rememberCredential", false)
                val username = values["username"].orEmpty()
                if (remember && username.isNotBlank()) {
                    onRemember(username, secretPassword())
                } else {
                    onForget()
                }
            }
            busy = false; status = null
            onAuthenticated()
        }
    }
}
