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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        useContinuousSystemBars()
        PortalPollWorker.ensureChannel(this)
        if (PortalHttp.hasSessionCookie()) {
            PortalSessionCoordinator.validate(application)
            openHome()
            return
        }
        setContent {
            PortalTheme {
                LoginRoute(
                    model = model,
                    openHome = ::openHome,
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
    private fun openHome() {
        startActivity(Intent(this, HomeActivity::class.java))
        overridePendingTransition(R.anim.fade_in, R.anim.activity_stay)
        finish()
    }
}

@Composable
private fun LoginRoute(
    model: LoginViewModel,
    openHome: () -> Unit,
    openWebLogin: () -> Unit,
    openSchoolSelection: () -> Unit
) {
    LaunchedEffect(model.authenticated) {
        if (model.authenticated) openHome()
    }
    if (model.authenticated) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
    } else {
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
    val density = LocalDensity.current
    val imeBottom = WindowInsets.ime.getBottom(density)
    val animatedImeProgress by animateFloatAsState(
        targetValue = if (imeBottom > 0) 1f else 0f,
        animationSpec = tween(durationMillis = 180, easing = LinearOutSlowInEasing),
        label = "login-ime-lift"
    )
    val contentLiftPx = with(density) { 48.dp.toPx() }
    val headerHeight = (154f - 100f * animatedImeProgress).dp

    LaunchedEffect(model.selectedSchoolId) {
        username = model.rememberedCredential?.username.orEmpty()
        password = model.rememberedCredential?.password.orEmpty()
        rememberPassword = model.rememberedCredential != null
    }

    Box(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .safeDrawingPadding()
            .imePadding()
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(horizontal = 24.dp, vertical = 40.dp),
            verticalArrangement = Arrangement.Top
        ) {
            item {
                Column(
                    modifier = Modifier.graphicsLayer {
                        translationY = -contentLiftPx * animatedImeProgress
                    }
                ) {
                    Column(
                        modifier = Modifier
                            .height(headerHeight)
                            .clipToBounds()
                            .graphicsLayer { alpha = 1f - animatedImeProgress }
                    ) {
                        Surface(Modifier.size(64.dp), RoundedCornerShape(20.dp), color = PortalBlue) {
                            Box(contentAlignment = Alignment.Center) {
                                Icon(
                                    Icons.Outlined.School,
                                    null,
                                    tint = MaterialTheme.colorScheme.onPrimary,
                                    modifier = Modifier.size(34.dp)
                                )
                            }
                        }
                        Spacer(Modifier.height(22.dp))
                        Text(
                            "掌上教务",
                            style = MaterialTheme.typography.headlineLarge,
                            color = MaterialTheme.colorScheme.onBackground,
                            fontWeight = FontWeight.Bold
                        )
                        Spacer(Modifier.height(28.dp))
                    }
                    androidx.compose.material3.Card(
                        shape = RoundedCornerShape(24.dp),
                        colors = CardDefaults.cardColors(containerColor = PortalCardBackground)
                    ) {
                        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        Text("账号密码登录", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                        OutlinedButton(
                            onClick = openSchoolSelection,
                            enabled = !model.loading,
                            modifier = Modifier.fillMaxWidth().height(54.dp)
                        ) {
                            Icon(Icons.Outlined.School, null)
                            Spacer(Modifier.size(8.dp))
                            Text(
                                model.schoolOptions.firstOrNull { it.id == model.selectedSchoolId }?.name.orEmpty(),
                                modifier = Modifier.weight(1f)
                            )
                            Icon(Icons.Outlined.ChevronRight, null)
                        }
                        OutlinedTextField(
                            value = username,
                            onValueChange = { username = it },
                            label = { Text("学号 / 账号") },
                            leadingIcon = { Icon(Icons.Outlined.AccountCircle, null) },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Text, imeAction = ImeAction.Next),
                            modifier = Modifier.fillMaxWidth()
                        )
                        OutlinedTextField(
                            value = password,
                            onValueChange = { password = it },
                            label = { Text("密码") },
                            leadingIcon = { Icon(Icons.Outlined.Key, null) },
                            trailingIcon = {
                                IconButton(onClick = { revealPassword = !revealPassword }) {
                                    Icon(if (revealPassword) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility, null)
                                }
                            },
                            singleLine = true,
                            visualTransformation = if (revealPassword) VisualTransformation.None else PasswordVisualTransformation(),
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
                            keyboardActions = KeyboardActions(onDone = {
                                model.login(username, password, rememberPassword)
                            }),
                            modifier = Modifier.fillMaxWidth()
                        )
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Checkbox(
                                checked = rememberPassword,
                                onCheckedChange = {
                                    rememberPassword = it
                                    if (!it) model.forgetPassword()
                                }
                            )
                            Text("记住密码", color = MaterialTheme.colorScheme.onSurface)
                        }
                        model.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                        Button(
                            onClick = { model.login(username, password, rememberPassword) },
                            enabled = !model.loading && username.isNotBlank() && password.isNotBlank(),
                            modifier = Modifier.fillMaxWidth().height(50.dp)
                        ) {
                            if (model.loading) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = MaterialTheme.colorScheme.onPrimary)
                            else { Icon(Icons.Outlined.Lock, null); Spacer(Modifier.size(8.dp)); Text("登录") }
                        }
                        HorizontalDivider()
                        OutlinedButton(onClick = openWebLogin, modifier = Modifier.fillMaxWidth().height(50.dp)) {
                            Icon(Icons.Outlined.OpenInBrowser, null)
                            Spacer(Modifier.size(8.dp))
                            Text("通过教务网页登录")
                        }
                        }
                    }
                }
            }
        }
    }
}
