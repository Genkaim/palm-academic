package cn.edu.cupk.portalreader

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * type=script 学校的登录控制器：持有离屏沙箱运行时与 schema 驱动的界面状态，
 * 负责账号密码 / 短信 / 扫码三类登录。密码仅在提交边界离开 Compose 状态进入原生。
 */
class ScriptLoginController(
    private val appContext: Context,
    private val scope: CoroutineScope,
    private val onAuthenticated: () -> Unit,
    private val onRemember: (username: String, password: String) -> Unit,
    private val onForget: () -> Unit
) {
    var phase by mutableStateOf(Phase.LOADING)
        private set
    var initError by mutableStateOf<String?>(null)
        private set
    var methods by mutableStateOf<List<LoginScriptRuntime.Method>>(emptyList())
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

    private fun currentMethod(): LoginScriptRuntime.Method? =
        methods.firstOrNull { it.id == methodId }

    fun selectMethod(method: LoginScriptRuntime.Method) {
        if (method.id == methodId) return
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
            // local 作用域的“记住账号/密码”复选框。
            val remember = checkboxes.getOrDefault("rememberCredential", false)
            val username = values["username"].orEmpty()
            if (remember && username.isNotBlank()) onRemember(username, secretPassword()) else onForget()
            busy = false; status = null
            onAuthenticated()
        }
    }
}

@Composable
internal fun ScriptLoginContent(
    controller: ScriptLoginController,
    schoolName: String,
    openSchoolSelection: () -> Unit
) {
    Column(
        Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .verticalScroll(rememberScrollState())
            .windowInsetsPadding(WindowInsets.systemBars)
            .padding(horizontal = 22.dp)
            .padding(top = 28.dp, bottom = 28.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            "掌上门户",
            fontSize = 26.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onBackground
        )
        Spacer(Modifier.height(6.dp))
        Text(
            schoolName,
            fontSize = 14.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.clickable { openSchoolSelection() }
        )
        Spacer(Modifier.height(22.dp))

        if (controller.phase == ScriptLoginController.Phase.LOADING) {
            CircularProgressIndicator()
            Spacer(Modifier.height(12.dp))
            Text("正在准备登录…", color = MaterialTheme.colorScheme.onSurfaceVariant)
            return@Column
        }
        controller.initError?.let {
            Text(it, color = MaterialTheme.colorScheme.error)
            return@Column
        }

        if (controller.methods.size > 1) {
            MethodTabs(controller)
            Spacer(Modifier.height(18.dp))
        }
        val method = controller.methods.firstOrNull { it.id == controller.methodId } ?: return@Column

        if (method.kind == "qrcode") {
            QrPanel(controller)
        } else {
            method.fields.forEach { field ->
                FieldInput(controller, field)
                Spacer(Modifier.height(12.dp))
            }
            method.checkboxes.forEach { box ->
                CheckboxRow(box.label, controller.checkboxes.getOrDefault(box.id, box.defaultChecked)) {
                    controller.toggleCheckbox(box.id)
                }
            }
            Spacer(Modifier.height(8.dp))
            controller.status?.let {
                Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)
                Spacer(Modifier.height(8.dp))
            }
            controller.error?.let {
                Text(it, color = MaterialTheme.colorScheme.error, fontSize = 13.sp)
                Spacer(Modifier.height(8.dp))
            }
            Button(
                onClick = { controller.submit() },
                enabled = !controller.busy,
                modifier = Modifier.fillMaxWidth().height(52.dp),
                shape = RoundedCornerShape(16.dp)
            ) {
                if (controller.busy) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(20.dp),
                        strokeWidth = 2.dp,
                        color = MaterialTheme.colorScheme.onPrimary
                    )
                } else {
                    Text("登录", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }

        controller.captchaChallenge?.let { CaptchaChallengeDialog(controller) }
        controller.failureDialog?.let { message ->
            FailureDialog(message, onRetry = controller::retryAfterFailure, onDismiss = controller::dismissFailure)
        }
    }
}

@Composable
private fun CaptchaChallengeDialog(controller: ScriptLoginController) {
    val bmp = controller.captchaDialogImage?.let {
        android.graphics.BitmapFactory.decodeByteArray(it, 0, it.size)
    }
    AlertDialog(
        onDismissRequest = { controller.dismissCaptchaDialog() },
        title = { Text("需要输入验证码") },
        text = {
            Column {
                Text("系统要求安全验证，请输入图形验证码。", fontSize = 13.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = controller.captchaDialogInput,
                    onValueChange = controller::typeCaptchaInput,
                    singleLine = true,
                    label = { Text("验证码") },
                    shape = RoundedCornerShape(12.dp)
                )
                Spacer(Modifier.height(10.dp))
                Box(
                    Modifier.size(width = 150.dp, height = 64.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                        .clickable { controller.refreshDialogCaptcha() },
                    contentAlignment = Alignment.Center
                ) {
                    if (bmp != null) {
                        Image(bmp.asImageBitmap(), "验证码", Modifier.fillMaxSize())
                    } else {
                        CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { controller.confirmCaptchaDialog() },
                enabled = controller.captchaDialogInput.isNotBlank()) { Text("确认登录") }
        },
        dismissButton = { TextButton(onClick = { controller.dismissCaptchaDialog() }) { Text("取消") } }
    )
}

@Composable
private fun FailureDialog(message: String, onRetry: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("登录失败") },
        text = { Text(message) },
        confirmButton = { TextButton(onClick = onRetry) { Text("重试") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("关闭") } }
    )
}

@Composable
private fun MethodTabs(controller: ScriptLoginController) {
    val tabs = controller.methods
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        tabs.forEachIndexed { index, method ->
            SegmentedButton(
                selected = method.id == controller.methodId,
                onClick = { controller.selectMethod(method) },
                shape = SegmentedButtonDefaults.itemShape(index, tabs.size)
            ) { Text(method.label, fontSize = 13.sp) }
        }
    }
}

@Composable
private fun FieldInput(controller: ScriptLoginController, field: LoginScriptRuntime.Field) {
    if (field.type == "captcha") {
        Row(verticalAlignment = Alignment.CenterVertically) {
            BasicField(
                controller = controller,
                field = field,
                modifier = Modifier.weight(1f),
                keyboardType = KeyboardType.Text
            )
            Spacer(Modifier.width(10.dp))
            val captchaBmp = controller.captchaImages[field.id]?.let {
                android.graphics.BitmapFactory.decodeByteArray(it, 0, it.size)
            }
            Box(
                Modifier
                    .size(width = 104.dp, height = 56.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .clickable { controller.refreshCaptcha(field) },
                contentAlignment = Alignment.Center
            ) {
                if (captchaBmp != null) {
                    Image(captchaBmp.asImageBitmap(), contentDescription = "验证码", Modifier.fillMaxSize())
                } else {
                    Text("获取", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        return
    }
    if (field.type == "smsCode") {
        Row(verticalAlignment = Alignment.CenterVertically) {
            BasicField(
                controller = controller,
                field = field,
                modifier = Modifier.weight(1f),
                keyboardType = KeyboardType.Number
            )
            Spacer(Modifier.width(10.dp))
            OutlinedButton(
                onClick = { controller.sendSms(field) },
                enabled = controller.smsCooldown == 0 && !controller.busy,
                modifier = Modifier.height(56.dp),
                shape = RoundedCornerShape(14.dp)
            ) {
                Text(
                    if (controller.smsCooldown > 0) "${controller.smsCooldown}s" else "获取验证码",
                    fontSize = 13.sp
                )
            }
        }
        return
    }
    val keyboardType = when (field.type) {
        "tel" -> KeyboardType.Phone
        "password" -> KeyboardType.Password
        else -> KeyboardType.Text
    }
    BasicField(controller, field, Modifier.fillMaxWidth(), keyboardType)
}

@Composable
private fun BasicField(
    controller: ScriptLoginController,
    field: LoginScriptRuntime.Field,
    modifier: Modifier,
    keyboardType: KeyboardType
) {
    var reveal by remember { mutableStateOf(false) }
    val isPassword = field.type == "password"
    OutlinedTextField(
        value = controller.values[field.id].orEmpty(),
        onValueChange = { controller.setValue(field.id, it) },
        modifier = modifier,
        singleLine = true,
        label = { Text(field.label) },
        placeholder = { field.placeholder.takeIf(String::isNotBlank)?.let { Text(it) } },
        shape = RoundedCornerShape(16.dp),
        visualTransformation = if (isPassword && !reveal) PasswordVisualTransformation()
        else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
        trailingIcon = if (isPassword) {
            { Text(if (reveal) "隐藏" else "显示", fontSize = 12.sp,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.clickable { reveal = !reveal }) }
        } else null
    )
}

@Composable
private fun CheckboxRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Checkbox(checked = checked, onCheckedChange = onChange)
        Text(label, fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurface)
    }
}

@Composable
private fun QrPanel(controller: ScriptLoginController) {
    val bmp = controller.qrImage
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            Modifier.size(232.dp).clip(RoundedCornerShape(18.dp))
                .background(Color.White).padding(12.dp),
            contentAlignment = Alignment.Center
        ) {
            if (bmp != null) {
                Image(bmp.asImageBitmap(), contentDescription = "登录二维码", Modifier.fillMaxSize())
            } else {
                CircularProgressIndicator()
            }
        }
        Spacer(Modifier.height(16.dp))
        Text(
            controller.qrMessage.ifBlank {
                when (controller.qrState) {
                    "scanned" -> "已扫码，请在手机上确认"
                    "expired" -> "二维码已过期"
                    else -> "请使用学校移动 App 或微信扫码登录"
                }
            },
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontSize = 14.sp
        )
        Spacer(Modifier.height(8.dp))
        controller.error?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 13.sp) }
    }
}
