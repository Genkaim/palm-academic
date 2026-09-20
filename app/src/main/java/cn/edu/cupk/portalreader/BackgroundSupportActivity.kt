package cn.edu.cupk.portalreader

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.widget.Toast
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
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat

class BackgroundSupportActivity : PortalActivity() {
    private var stateVersion by mutableIntStateOf(0)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        useContinuousSystemBars()
        setContent {
            PortalTheme {
                BackgroundSupportContent(
                    onBack = { finish() },
                    stateVersion = stateVersion
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        stateVersion++
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BackgroundSupportContent(onBack: () -> Unit, stateVersion: Int) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val preferences = remember { PortalNotificationPreferences.preferences(context) }
    var persistentNotification by remember {
        mutableStateOf(
            preferences.getBoolean(PortalNotificationPreferences.KEY_PERSISTENT_NOTIFICATION, false)
        )
    }
    val supportState = remember(stateVersion) { BackgroundSupport.inspect(context) }
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (
            granted && PortalKeepAliveService.canShowNotification(context) &&
            PortalKeepAliveService.setEnabled(context, true)
        ) {
            persistentNotification = true
        } else {
            PortalKeepAliveService.setEnabled(context, false)
            persistentNotification = false
            Toast.makeText(context, "需要通知权限才能显示保活通知", Toast.LENGTH_SHORT).show()
        }
    }
    val changePersistentNotification: (Boolean) -> Unit = { enabled ->
        if (!enabled) {
            if (PortalKeepAliveService.setEnabled(context, false)) persistentNotification = false
        } else if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else if (!PortalKeepAliveService.canShowNotification(context)) {
            persistentNotification = false
            Toast.makeText(context, "请先允许掌上教务发送通知", Toast.LENGTH_SHORT).show()
            BackgroundSupport.openNotificationSettings(context)
        } else if (PortalKeepAliveService.setEnabled(context, true)) {
            persistentNotification = true
        }
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text("保活检测") },
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
                    Column {
                        Row(
                            Modifier.fillMaxWidth().padding(18.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Icon(Icons.Outlined.Sync, null, tint = PortalBlue)
                            Spacer(Modifier.size(14.dp))
                            Column {
                                Text("后台运行支持", fontWeight = FontWeight.SemiBold)
                                Text(
                                    "检查系统对后台检测的限制",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                        HorizontalDivider(Modifier.padding(horizontal = 18.dp))
                        SupportStatusRow(
                            title = "自启动",
                            status = if (supportState.bootReceiverAvailable) "需在系统设置中确认" else "应用自启动组件已禁用",
                            healthy = if (supportState.bootReceiverAvailable) null else false,
                            onClick = { BackgroundSupport.openAutoStartSettings(context) }
                        )
                        SupportStatusRow(
                            title = "电池优化",
                            status = if (supportState.batteryOptimizationIgnored) "不受电池优化限制" else "受到电池优化限制",
                            healthy = supportState.batteryOptimizationIgnored,
                            onClick = { BackgroundSupport.openBatterySettings(context) }
                        )
                        SupportStatusRow(
                            title = "后台运行限制",
                            status = if (supportState.backgroundRestricted) "系统已限制后台运行" else "未检测到后台限制",
                            healthy = !supportState.backgroundRestricted,
                            onClick = { BackgroundSupport.openAppDetails(context) }
                        )
                        SupportStatusRow(
                            title = "通知权限",
                            status = if (supportState.notificationsEnabled) "通知已允许" else "通知未允许",
                            healthy = supportState.notificationsEnabled,
                            onClick = { BackgroundSupport.openNotificationSettings(context) }
                        )
                        HorizontalDivider(Modifier.padding(horizontal = 18.dp))
                        Row(
                            Modifier.fillMaxWidth().padding(18.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text("常驻通知保活", fontWeight = FontWeight.SemiBold)
                                Text(
                                    "显示常驻通知以提高后台检测存活率",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            Switch(
                                checked = persistentNotification,
                                onCheckedChange = changePersistentNotification
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SupportStatusRow(
    title: String,
    status: String,
    healthy: Boolean?,
    onClick: () -> Unit
) {
    Row(
        Modifier.fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Text(
                status,
                style = MaterialTheme.typography.bodySmall,
                color = when (healthy) {
                    true -> PortalSuccess
                    false -> MaterialTheme.colorScheme.error
                    null -> MaterialTheme.colorScheme.onSurfaceVariant
                }
            )
        }
        Icon(Icons.Outlined.ChevronRight, null, tint = MaterialTheme.colorScheme.outline)
    }
}
