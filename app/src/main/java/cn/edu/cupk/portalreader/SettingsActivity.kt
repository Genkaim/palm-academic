package cn.edu.cupk.portalreader

import android.content.Intent
import android.app.Activity
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.Palette
import androidx.compose.material.icons.outlined.School
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material.icons.outlined.Update
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

class SettingsActivity : PortalActivity() {
    private val schoolSelectionLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            result.data?.getStringExtra(SchoolSelectionActivity.EXTRA_RESULT_SCHOOL_ID)
                ?.let(::switchSchool)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        useContinuousSystemBars()
        setContent {
            PortalTheme {
                SettingsContent(
                    onBack = { finish() },
                    onNotifications = {
                        startActivity(Intent(this, NotificationSettingsActivity::class.java))
                    },
                    onBackgroundSupport = {
                        startActivity(Intent(this, BackgroundSupportActivity::class.java))
                    },
                    onOpenSchoolSelection = {
                        schoolSelectionLauncher.launch(
                            Intent(this, SchoolSelectionActivity::class.java)
                                .putExtra(
                                    SchoolSelectionActivity.EXTRA_SELECTED_SCHOOL_ID,
                                    SchoolAdapterRepository.activeSchoolId()
                                )
                                .putExtra(SchoolSelectionActivity.EXTRA_REQUIRES_LOGIN, true)
                        )
                    },
                    onLogout = ::logout
                )
            }
        }
    }

    private fun switchSchool(schoolId: String) {
        if (!SchoolAdapterRepository.select(this, schoolId)) return
        PortalMonitor.cancel(this)
        PortalSessionCoordinator.clear()
        PortalHttp.clearSession {
            startActivity(
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            )
            finish()
        }
    }

    private fun logout() {
        PortalMonitor.cancel(this)
        PortalSessionCoordinator.clear()
        PortalHttp.clearSession {
            startActivity(
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            )
            finish()
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsContent(
    onBack: () -> Unit,
    onNotifications: () -> Unit,
    onBackgroundSupport: () -> Unit,
    onOpenSchoolSelection: () -> Unit,
    onLogout: () -> Unit
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val selectedSchoolName = remember { SchoolAdapterRepository.activeName(context) }
    var confirmLogout by remember { mutableStateOf(false) }
    var checkingUpdate by remember { mutableStateOf(false) }
    var availableRelease by remember { mutableStateOf<GitHubRelease?>(null) }
    val scope = rememberCoroutineScope()
    val themeMode = PortalThemePreferences.mode

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text("设置") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Outlined.ArrowBack, "返回")
                    }
                }
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier.padding(padding).fillMaxSize(),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            item {
                Card(
                    shape = RoundedCornerShape(18.dp),
                    colors = CardDefaults.cardColors(containerColor = PortalCardBackground)
                ) {
                    Column(
                        Modifier.fillMaxWidth().padding(18.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Outlined.Palette, null, tint = PortalBlue)
                            Spacer(Modifier.size(14.dp))
                            Column {
                                Text("外观", fontWeight = FontWeight.SemiBold)
                                Text(
                                    "选择应用的显示模式",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            PortalThemeMode.entries.forEach { mode ->
                                FilterChip(
                                    selected = themeMode == mode,
                                    onClick = { PortalThemePreferences.set(context, mode) },
                                    label = { Text(mode.displayName) }
                                )
                            }
                        }
                    }
                }
            }
            item {
                SettingsNavigationCard(
                    title = "学校",
                    description = selectedSchoolName,
                    icon = { Icon(Icons.Outlined.School, null, tint = PortalBlue) },
                    onClick = onOpenSchoolSelection
                )
            }
            item {
                SettingsNavigationCard(
                    title = "变动通知",
                    description = "分别设置课表、成绩与考试提醒",
                    icon = { Icon(Icons.Outlined.Notifications, null, tint = PortalBlue) },
                    onClick = onNotifications
                )
            }
            item {
                SettingsNavigationCard(
                    title = "保活检测",
                    description = "检查自启动、电池优化与后台限制",
                    icon = { Icon(Icons.Outlined.Sync, null, tint = PortalBlue) },
                    onClick = onBackgroundSupport
                )
            }
            item {
                SettingsNavigationCard(
                    title = "检查更新",
                    description = if (checkingUpdate) {
                        "正在通过 GitHub Releases 检查…"
                    } else {
                        "当前版本 ${BuildConfig.VERSION_NAME}"
                    },
                    icon = { Icon(Icons.Outlined.Update, null, tint = PortalBlue) },
                    onClick = {
                        if (!checkingUpdate) {
                            checkingUpdate = true
                            scope.launch {
                                runCatching { PalmAcademicGitHub.latestRelease() }
                                    .onSuccess { release ->
                                        if (release.isNewerThan(BuildConfig.VERSION_NAME)) {
                                            availableRelease = release
                                        } else {
                                            Toast.makeText(context, "当前已是最新版本", Toast.LENGTH_SHORT).show()
                                        }
                                    }
                                    .onFailure { error ->
                                        Toast.makeText(
                                            context,
                                            "${error.message ?: "检查更新失败"}。服务托管于Github，请注意网络环境",
                                            Toast.LENGTH_LONG
                                        ).show()
                                    }
                                checkingUpdate = false
                            }
                        }
                    }
                )
            }
            item {
                OutlinedButton(
                    onClick = { confirmLogout = true },
                    modifier = Modifier.fillMaxWidth()
                ) { Text("退出登录") }
            }
        }
    }

    if (confirmLogout) {
        AlertDialog(
            onDismissRequest = { confirmLogout = false },
            title = { Text("退出登录？") },
            text = { Text("将清除本应用中的登录会话并停止后台监测。") },
            confirmButton = {
                Button(onClick = { confirmLogout = false; onLogout() }) { Text("退出") }
            },
            dismissButton = {
                OutlinedButton(onClick = { confirmLogout = false }) { Text("取消") }
            }
        )
    }
    availableRelease?.let { release ->
        AlertDialog(
            onDismissRequest = { availableRelease = null },
            title = { Text("发现新版本 ${release.tagName}") },
            text = {
                Text(
                    release.notes.ifBlank { "新版本已发布，可前往 GitHub 下载更新。" }
                        .take(2000)
                )
            },
            confirmButton = {
                Button(onClick = {
                    availableRelease = null
                    context.startActivity(
                        Intent(Intent.ACTION_VIEW, Uri.parse(release.apkUrl ?: release.pageUrl))
                    )
                }) { Text(if (release.apkUrl != null) "下载 APK" else "查看 Release") }
            },
            dismissButton = {
                OutlinedButton(onClick = { availableRelease = null }) { Text("稍后") }
            }
        )
    }
}

@Composable
private fun SettingsNavigationCard(
    title: String,
    description: String,
    icon: @Composable () -> Unit,
    onClick: () -> Unit
) {
    Card(
        modifier = Modifier.clickable(onClick = onClick),
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = PortalCardBackground)
    ) {
        Row(
            Modifier.fillMaxWidth().padding(18.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            icon()
            Spacer(Modifier.size(14.dp))
            Column(Modifier.weight(1f)) {
                Text(title, fontWeight = FontWeight.SemiBold)
                Text(
                    description,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Icon(Icons.Outlined.ChevronRight, null, tint = MaterialTheme.colorScheme.outline)
        }
    }
}
