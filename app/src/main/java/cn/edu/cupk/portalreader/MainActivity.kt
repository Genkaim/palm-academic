package cn.edu.cupk.portalreader

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.imeAnimationSource
import androidx.compose.foundation.layout.imeAnimationTarget
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AccountCircle
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.OpenInBrowser
import androidx.compose.material.icons.outlined.School
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class LoginViewModel(application: Application) : AndroidViewModel(application) {
    var schoolOptions by mutableStateOf(SchoolAdapterRepository.options(application))
        private set
    var selectedSchoolId by mutableStateOf(SchoolAdapterRepository.activeSchoolId())
        private set
    var rememberedCredential by mutableStateOf(PasswordCredentialStore.load(application))
        private set
    var loading by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    var authenticated by mutableStateOf(false)
        private set

    private val auth = AuthRepository()

    fun login(username: String, password: String, rememberPassword: Boolean = false) {
        loading = true
        error = null
        val loginSchoolId = selectedSchoolId
        viewModelScope.launch {
            auth.login(username, password)
                .onSuccess {
                    if (rememberPassword) {
                        PasswordCredentialStore.save(getApplication(), username, password, loginSchoolId)
                    } else {
                        PasswordCredentialStore.clear(getApplication(), loginSchoolId)
                    }
                    completeAuthentication()
                }
                .onFailure { error = it.message ?: "登录失败" }
            loading = false
        }
    }

    fun forgetPassword() {
        PasswordCredentialStore.clear(getApplication(), selectedSchoolId)
    }

    fun selectSchool(schoolId: String) {
        schoolOptions = SchoolAdapterRepository.options(getApplication())
        if (loading || !SchoolAdapterRepository.select(getApplication(), schoolId)) return
        PortalMonitor.cancel(getApplication())
        PortalHttp.clearSession()
        selectedSchoolId = schoolId
        rememberedCredential = PasswordCredentialStore.load(getApplication(), schoolId)
        error = null
        PortalSessionCoordinator.clear()
    }

    fun completeAuthentication() {
        clearAuthenticationFailureMarker()
        QuickEntryBaseline.request(getApplication())
        PortalMonitor.schedule(getApplication(), preferredInterval())
        PortalSessionCoordinator.markAuthenticated()
        authenticated = true
        loading = false
        error = null
    }

    private fun preferredInterval(): Long = getApplication<Application>()
        .getSharedPreferences(PortalPollWorker.PREFS, android.content.Context.MODE_PRIVATE)
        .getLong("interval", 30L)

    private fun clearAuthenticationFailureMarker() {
        PortalNotificationPreferences.preferences(getApplication())
            .edit()
            .putBoolean(PortalPollWorker.KEY_AUTH_FAILURE_NOTIFIED, false)
            .apply()
    }
}

class MainActivity : PortalActivity() {
    private val model: LoginViewModel by viewModels()
    private var homeOpening = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val openedFromNotification = intent.getBooleanExtra(EXTRA_NOTIFICATION_ENTRY, false)
        if (openedFromNotification) {
            @Suppress("DEPRECATION")
            overridePendingTransition(R.anim.fade_in, R.anim.activity_stay)
        }
        useContinuousSystemBars()
        PortalPollWorker.ensureChannel(this)
        val resumeExistingSession = PortalHttp.hasSessionCookie()
        if (resumeExistingSession) {
            PortalSessionCoordinator.validate(application)
            openHome(
                animateLoginExit = false,
                animateNotificationEntry = openedFromNotification
            )
            return
        }
        setContent {
            PortalTheme {
                LoginRoute(
                    model = model,
                    openHome = { openHome(animateLoginExit = true) },
                    openWebLogin = { webLoginLauncher.launch(Intent(this, WebLoginActivity::class.java)) },
                    openSchoolSelection = {
                        schoolSelectionLauncher.launch(
                            Intent(this, SchoolSelectionActivity::class.java)
                                .putExtra(
                                    SchoolSelectionActivity.EXTRA_SELECTED_SCHOOL_ID,
                                    model.selectedSchoolId
                                )
                                .putExtra(SchoolSelectionActivity.EXTRA_REQUIRES_LOGIN, false)
                        )
                    }
                )
            }
        }
    }

    private val webLoginLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK) model.completeAuthentication()
    }

    private val schoolSelectionLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            result.data?.getStringExtra(SchoolSelectionActivity.EXTRA_RESULT_SCHOOL_ID)
                ?.let(model::selectSchool)
        }
    }

    @Suppress("DEPRECATION")
    private fun openHome(
        animateLoginExit: Boolean,
        animateNotificationEntry: Boolean = false
    ) {
        if (homeOpening) return
        homeOpening = true
        startActivity(
            Intent(this, HomeActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)
                .putExtra(HomeActivity.EXTRA_LOGIN_ENTRY_ANIMATION, animateLoginExit)
                .putExtra(
                    HomeActivity.EXTRA_NOTIFICATION_ENTRY_ANIMATION,
                    animateNotificationEntry
                )
        )
        overridePendingTransition(0, 0)
        finish()
        overridePendingTransition(0, 0)
    }

    companion object {
        const val EXTRA_NOTIFICATION_ENTRY = "notification_entry"
    }
}

@Composable
private fun LoginRoute(
    model: LoginViewModel,
    openHome: () -> Unit,
    openWebLogin: () -> Unit,
    openSchoolSelection: () -> Unit
) {
    var loginExiting by remember { mutableStateOf(false) }
    val loginAlpha by animateFloatAsState(
        targetValue = if (loginExiting) 0f else 1f,
        animationSpec = tween(durationMillis = 110, easing = LinearOutSlowInEasing),
        label = "login-page-exit"
    )
    LaunchedEffect(model.authenticated) {
        if (model.authenticated && !loginExiting) {
            loginExiting = true
            delay(110)
            openHome()
        }
    }
    Box(
        Modifier
            .fillMaxSize()
            .graphicsLayer { alpha = loginAlpha }
    ) {
        LoginContent(model, openWebLogin, openSchoolSelection)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun LoginContent(
    model: LoginViewModel,
    openWebLogin: () -> Unit,
    openSchoolSelection: () -> Unit
) {
    var username by remember { mutableStateOf(model.rememberedCredential?.username.orEmpty()) }
    var password by remember { mutableStateOf(model.rememberedCredential?.password.orEmpty()) }
    var rememberPassword by remember { mutableStateOf(model.rememberedCredential != null) }
    var revealPassword by remember { mutableStateOf(false) }
    var usernameFocused by remember { mutableStateOf(false) }
    var passwordFocused by remember { mutableStateOf(false) }
    val density = LocalDensity.current
    val credentialInputFocused = usernameFocused || passwordFocused
    val animatedFocusProgress by animateFloatAsState(
        targetValue = if (credentialInputFocused) 1f else 0f,
        animationSpec = tween(durationMillis = 110, easing = LinearOutSlowInEasing),
        label = "login-focus-lift"
    )
    val imeBottom = WindowInsets.ime.getBottom(density)
    val imeAnimationSourceBottom = WindowInsets.imeAnimationSource.getBottom(density)
    val imeAnimationTargetBottom = WindowInsets.imeAnimationTarget.getBottom(density)
    val imeAnimationRange = maxOf(
        imeBottom,
        imeAnimationSourceBottom,
        imeAnimationTargetBottom
    )
    // Insets expose every frame of the system keyboard animation. Using its actual fraction
    // avoids waiting for isImeVisible to flip only after the closing animation has finished.
    val rawImeAnimationProgress = if (imeAnimationRange > 0) {
        (imeBottom.toFloat() / imeAnimationRange).coerceIn(0f, 1f)
    } else {
        0f
    }
    val imeAnimationProgress = if (imeAnimationSourceBottom > imeAnimationTargetBottom) {
        // Move ahead of the comparatively slow system keyboard closing animation.
        rawImeAnimationProgress * rawImeAnimationProgress
    } else {
        rawImeAnimationProgress
    }
    val loginLiftProgress = minOf(animatedFocusProgress, imeAnimationProgress)
    val contentLiftPx = with(density) { 48.dp.toPx() }
    val headerHeight = (154f - 100f * loginLiftProgress).dp

    LaunchedEffect(model.selectedSchoolId) {
        username = model.rememberedCredential?.username.orEmpty()
        password = model.rememberedCredential?.password.orEmpty()
        rememberPassword = model.rememberedCredential != null
    }

    val fieldColors = TextFieldDefaults.colors(
        focusedContainerColor = MaterialTheme.colorScheme.surface,
        unfocusedContainerColor = MaterialTheme.colorScheme.surface,
        disabledContainerColor = MaterialTheme.colorScheme.surface,
        focusedIndicatorColor = Color.Transparent,
        unfocusedIndicatorColor = Color.Transparent,
        disabledIndicatorColor = Color.Transparent,
        focusedTextColor = MaterialTheme.colorScheme.onSurface,
        unfocusedTextColor = MaterialTheme.colorScheme.onSurface,
        focusedLabelColor = MaterialTheme.colorScheme.onSurfaceVariant,
        unfocusedLabelColor = MaterialTheme.colorScheme.onSurfaceVariant,
        focusedLeadingIconColor = MaterialTheme.colorScheme.onSurface,
        unfocusedLeadingIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
        cursorColor = MaterialTheme.colorScheme.onSurface
    )
    val selectedSchoolName = model.schoolOptions
        .firstOrNull { it.id == model.selectedSchoolId }
        ?.name
        .orEmpty()

    Box(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .safeDrawingPadding()
            .imePadding()
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(horizontal = 20.dp, vertical = 28.dp),
            verticalArrangement = Arrangement.Top
        ) {
            item {
                Column(
                    modifier = Modifier.graphicsLayer {
                        translationY = -contentLiftPx * loginLiftProgress
                    }
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(headerHeight)
                            .clipToBounds()
                            .graphicsLayer { alpha = 1f - loginLiftProgress },
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        Surface(
                            modifier = Modifier.size(62.dp),
                            shape = RoundedCornerShape(19.dp),
                            color = MaterialTheme.colorScheme.surfaceVariant
                        ) {
                            Box(contentAlignment = Alignment.Center) {
                                Icon(
                                    Icons.Outlined.School,
                                    null,
                                    tint = MaterialTheme.colorScheme.onSurface,
                                    modifier = Modifier.size(31.dp)
                                )
                            }
                        }
                        Spacer(Modifier.height(16.dp))
                        Text(
                            "掌上教务",
                            style = MaterialTheme.typography.headlineMedium,
                            color = MaterialTheme.colorScheme.onBackground,
                            fontWeight = FontWeight.Bold
                        )
                        Spacer(Modifier.height(5.dp))
                        Text(
                            "登录以访问你的教务信息",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }

                    LoginSectionLabel("学校")
                    Card(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(18.dp))
                            .clickable(enabled = !model.loading, onClick = openSchoolSelection),
                        shape = RoundedCornerShape(18.dp),
                        colors = CardDefaults.cardColors(containerColor = PortalCardBackground),
                        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
                    ) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp, vertical = 15.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Icon(
                                Icons.Outlined.School,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSurface,
                                modifier = Modifier.size(22.dp)
                            )
                            Spacer(Modifier.size(13.dp))
                            Text(
                                selectedSchoolName,
                                modifier = Modifier.weight(1f),
                                color = MaterialTheme.colorScheme.onSurface,
                                fontWeight = FontWeight.Medium
                            )
                            Icon(
                                Icons.Outlined.ChevronRight,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.outline
                            )
                        }
                    }

                    Spacer(Modifier.height(20.dp))
                    LoginSectionLabel("登录信息")
                    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        TextField(
                            value = username,
                            onValueChange = { username = it },
                            label = { Text("学号 / 账号") },
                            leadingIcon = { Icon(Icons.Outlined.AccountCircle, null) },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Text, imeAction = ImeAction.Next),
                            shape = RoundedCornerShape(
                                topStart = 18.dp,
                                topEnd = 18.dp,
                                bottomStart = 6.dp,
                                bottomEnd = 6.dp
                            ),
                            colors = fieldColors,
                            modifier = Modifier
                                .fillMaxWidth()
                                .onFocusChanged { usernameFocused = it.isFocused }
                        )
                        TextField(
                            value = password,
                            onValueChange = { password = it },
                            label = { Text("密码") },
                            leadingIcon = { Icon(Icons.Outlined.Key, null) },
                            trailingIcon = {
                                IconButton(onClick = { revealPassword = !revealPassword }) {
                                    Icon(
                                        if (revealPassword) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility,
                                        if (revealPassword) "隐藏密码" else "显示密码"
                                    )
                                }
                            },
                            singleLine = true,
                            visualTransformation = if (revealPassword) VisualTransformation.None else PasswordVisualTransformation(),
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
                            keyboardActions = KeyboardActions(onDone = {
                                model.login(username, password, rememberPassword)
                            }),
                            shape = RoundedCornerShape(
                                topStart = 6.dp,
                                topEnd = 6.dp,
                                bottomStart = 18.dp,
                                bottomEnd = 18.dp
                            ),
                            colors = fieldColors,
                            modifier = Modifier
                                .fillMaxWidth()
                                .onFocusChanged { passwordFocused = it.isFocused }
                        )
                    }

                    Spacer(Modifier.height(10.dp))
                    Card(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(18.dp))
                            .clickable {
                                rememberPassword = !rememberPassword
                                if (!rememberPassword) model.forgetPassword()
                            },
                        shape = RoundedCornerShape(18.dp),
                        colors = CardDefaults.cardColors(containerColor = PortalCardBackground),
                        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
                    ) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                "记住密码",
                                modifier = Modifier.weight(1f),
                                color = MaterialTheme.colorScheme.onSurface,
                                fontWeight = FontWeight.Medium
                            )
                            Switch(
                                checked = rememberPassword,
                                onCheckedChange = {
                                    rememberPassword = it
                                    if (!it) model.forgetPassword()
                                },
                                colors = SwitchDefaults.colors(
                                    checkedThumbColor = MaterialTheme.colorScheme.onPrimary,
                                    checkedTrackColor = MaterialTheme.colorScheme.primary,
                                    uncheckedThumbColor = MaterialTheme.colorScheme.outline,
                                    uncheckedTrackColor = MaterialTheme.colorScheme.surfaceVariant,
                                    uncheckedBorderColor = Color.Transparent
                                )
                            )
                        }
                    }

                    model.error?.let { message ->
                        Spacer(Modifier.height(10.dp))
                        Surface(
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(14.dp),
                            color = MaterialTheme.colorScheme.errorContainer
                        ) {
                            Text(
                                message,
                                modifier = Modifier.padding(horizontal = 14.dp, vertical = 11.dp),
                                color = MaterialTheme.colorScheme.onErrorContainer,
                                style = MaterialTheme.typography.bodyMedium
                            )
                        }
                    }

                    Spacer(Modifier.height(18.dp))
                    Button(
                        onClick = { model.login(username, password, rememberPassword) },
                        enabled = !model.loading && username.isNotBlank() && password.isNotBlank(),
                        modifier = Modifier.fillMaxWidth().height(54.dp),
                        shape = RoundedCornerShape(16.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.primary,
                            contentColor = MaterialTheme.colorScheme.onPrimary,
                            disabledContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                            disabledContentColor = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    ) {
                        if (model.loading) {
                            CircularProgressIndicator(
                                Modifier.size(20.dp),
                                strokeWidth = 2.dp,
                                color = MaterialTheme.colorScheme.onPrimary
                            )
                        } else {
                            Icon(Icons.Outlined.Lock, null)
                            Spacer(Modifier.size(8.dp))
                            Text("登录", fontWeight = FontWeight.SemiBold)
                        }
                    }
                    Spacer(Modifier.height(10.dp))
                    Button(
                        onClick = openWebLogin,
                        modifier = Modifier.fillMaxWidth().height(52.dp),
                        shape = RoundedCornerShape(16.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.surface,
                            contentColor = MaterialTheme.colorScheme.onSurface
                        ),
                        elevation = ButtonDefaults.buttonElevation(defaultElevation = 0.dp)
                    ) {
                            Icon(Icons.Outlined.OpenInBrowser, null)
                            Spacer(Modifier.size(8.dp))
                            Text("通过教务网页登录")
                    }
                }
            }
        }
    }
}

@Composable
private fun LoginSectionLabel(text: String) {
    Text(
        text = text,
        modifier = Modifier.padding(start = 8.dp, bottom = 6.dp),
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        fontWeight = FontWeight.SemiBold
    )
}
