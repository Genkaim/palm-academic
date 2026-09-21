package cn.edu.cupk.portalreader

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat

private data class NotificationSetting(
    val key: String,
    val title: String,
    val description: String
)

class NotificationSettingsActivity : PortalActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        useContinuousSystemBars()
        PortalPollWorker.ensureChannel(this)
        setContent {
            PortalTheme {
                NotificationSettingsContent(
                    onBack = { finish() },
                    onOpenHistory = {
                        startActivity(Intent(this, NotificationHistoryActivity::class.java))
                    }
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NotificationSettingsContent(onBack: () -> Unit, onOpenHistory: () -> Unit) {
    val context = LocalContext.current
    val preferences = remember { PortalNotificationPreferences.preferences(context) }
    val settings = remember {
        listOf(
            NotificationSetting(
                PortalNotificationPreferences.KEY_SCHEDULE,
                "课表变动",
                "课表新增，或课程、时间、教师、教室发生变化时通知"
            ),
            NotificationSetting(
                PortalNotificationPreferences.KEY_GRADE,
                "成绩变动",
                "课程成绩新增或已有成绩发生变化时通知"
            ),
            NotificationSetting(
                PortalNotificationPreferences.KEY_EXAM,
                "考试变动",
                "考试新增，或考试时间、地点等安排发生变化时通知"
            )
        )
    }
    var enabledKeys by remember {
        mutableStateOf(settings.filter { PortalNotificationPreferences.isEnabled(preferences, it.key) }.map { it.key }.toSet())
    }
    var interval by remember { mutableLongStateOf(preferences.getLong("interval", 30L)) }
    var notificationPermissionGranted by remember {
        mutableStateOf(
            Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        )
    }
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        notificationPermissionGranted = it
    }
    LaunchedEffect(Unit) {
        if (Build.VERSION.SDK_INT >= 33 && !notificationPermissionGranted) {
            permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text("通知设置") },
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
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            item {
                Card(
                    shape = RoundedCornerShape(18.dp),
                    colors = CardDefaults.cardColors(containerColor = PortalControlBackground)
                ) {
                    Row(
                        Modifier.fillMaxWidth().padding(18.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(Icons.Outlined.Notifications, null, tint = PortalBlue)
                        Spacer(Modifier.size(14.dp))
                        Column {
                            Text("后台通知检测", fontWeight = FontWeight.SemiBold)
                            Text(
                                "分别选择需要接收的课表、成绩和考试变动提醒。",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }
            }
            item {
                Card(
                    shape = RoundedCornerShape(18.dp),
                    colors = CardDefaults.cardColors(containerColor = PortalCardBackground)
                ) {
                    Column(
                        Modifier.fillMaxWidth().padding(18.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Text("检查间隔", fontWeight = FontWeight.SemiBold)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            listOf(15L, 30L, 60L).forEach { value ->
                                FilterChip(
                                    selected = interval == value,
                                    onClick = {
                                        interval = value
                                        preferences.edit().putLong("interval", value).apply()
                                        if (PortalNotificationPreferences.anyEnabled(preferences)) {
                                            PortalMonitor.schedule(context, value)
                                        }
                                    },
                                    label = { Text("${value} 分钟") }
                                )
                            }
                        }
                        Text(
                            "实际执行时间会受网络和系统省电策略影响。",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
            items(settings.size) { index ->
                val setting = settings[index]
                val checked = setting.key in enabledKeys
                Card(
                    shape = RoundedCornerShape(18.dp),
                    colors = CardDefaults.cardColors(containerColor = PortalCardBackground)
                ) {
                    Row(
                        Modifier.fillMaxWidth().padding(18.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(setting.title, fontWeight = FontWeight.SemiBold)
                            Text(
                                setting.description,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Spacer(Modifier.size(12.dp))
                        Switch(
                            checked = checked,
                            onCheckedChange = { enabled ->
                                enabledKeys = if (enabled) enabledKeys + setting.key else enabledKeys - setting.key
                                preferences.edit().putBoolean(setting.key, enabled).apply()
                                PortalMonitor.reconcile(context)
                                if (enabled && Build.VERSION.SDK_INT >= 33 && !notificationPermissionGranted) {
                                    permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                                }
                            }
                        )
                    }
                }
            }
            if (!notificationPermissionGranted && enabledKeys.isNotEmpty()) {
                item {
                    Text(
                        "系统通知权限尚未开启，开启任一提醒时会再次申请权限。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error
                    )
                }
            }
            item {
                Card(
                    modifier = Modifier.fillMaxWidth().clickable(onClick = onOpenHistory),
                    shape = RoundedCornerShape(18.dp),
                    colors = CardDefaults.cardColors(containerColor = PortalCardBackground)
                ) {
                    Row(
                        Modifier.fillMaxWidth().padding(18.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(Icons.Outlined.History, null, tint = PortalBlue)
                        Spacer(Modifier.size(14.dp))
                        Column(Modifier.weight(1f)) {
                            Text("检查日志", fontWeight = FontWeight.SemiBold)
                            Text(
                                "查看通知检测历史与变动详情",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Icon(
                            Icons.Outlined.ChevronRight,
                            null,
                            tint = MaterialTheme.colorScheme.outline
                        )
                    }
                }
            }
        }
    }
}
