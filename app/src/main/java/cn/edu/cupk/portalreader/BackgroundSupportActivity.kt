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
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.kyant.backdrop.backdrops.layerBackdrop
import com.kyant.backdrop.backdrops.rememberLayerBackdrop

private enum class SupportGroupPosition { ONLY, FIRST, MIDDLE, LAST }

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

    val pageBackground = MaterialTheme.colorScheme.background
    val switchBackdrop = rememberLayerBackdrop {
        drawRect(pageBackground)
        drawContent()
    }
    Box(Modifier.fillMaxSize()) {
        Box(
            Modifier
                .fillMaxSize()
                .background(pageBackground)
                .layerBackdrop(switchBackdrop)
        )
        Scaffold(
        containerColor = androidx.compose.ui.graphics.Color.Transparent,
        topBar = {
            PortalGradientTopAppBar(
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
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                start = 16.dp,
                top = (padding.calculateTopPadding() - PortalTopFadeDepth).coerceAtLeast(0.dp) + 16.dp,
                end = 16.dp,
                bottom = padding.calculateBottomPadding() + 16.dp
            ),
            verticalArrangement = Arrangement.spacedBy(24.dp)
        ) {
            item {
                SupportSection("系统状态") {
                    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        SupportPanel(
                            position = SupportGroupPosition.FIRST,
                            onClick = { BackgroundSupport.openAutoStartSettings(context) }
                        ) {
                            SupportStatusRow(
                                title = "自启动",
                                status = if (supportState.bootReceiverAvailable) {
                                    "需在系统设置中确认"
                                } else {
                                    "应用自启动组件已禁用"
                                },
                                healthy = if (supportState.bootReceiverAvailable) null else false
                            )
                        }
                        SupportPanel(
                            position = SupportGroupPosition.MIDDLE,
                            onClick = { BackgroundSupport.openBatterySettings(context) }
                        ) {
                            SupportStatusRow(
                                title = "电池优化",
                                status = if (supportState.batteryOptimizationIgnored) {
                                    "不受电池优化限制"
                                } else {
                                    "受到电池优化限制"
                                },
                                healthy = supportState.batteryOptimizationIgnored
                            )
                        }
                        SupportPanel(
                            position = SupportGroupPosition.MIDDLE,
                            onClick = { BackgroundSupport.openAppDetails(context) }
                        ) {
                            SupportStatusRow(
                                title = "后台运行限制",
                                status = if (supportState.backgroundRestricted) {
                                    "系统已限制后台运行"
                                } else {
                                    "未检测到后台限制"
                                },
                                healthy = !supportState.backgroundRestricted
                            )
                        }
                        SupportPanel(
                            position = SupportGroupPosition.LAST,
                            onClick = { BackgroundSupport.openNotificationSettings(context) }
                        ) {
                            SupportStatusRow(
                                title = "通知权限",
                                status = if (supportState.notificationsEnabled) {
                                    "通知已允许"
                                } else {
                                    "通知未允许"
                                },
                                healthy = supportState.notificationsEnabled
                            )
                        }
                    }
                }
            }
            item {
                SupportSection("保活方式") {
                    SupportPanel(SupportGroupPosition.ONLY) {
                        Row(
                            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 15.dp),
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
                            PortalGlassSwitch(
                                checked = persistentNotification,
                                onCheckedChange = changePersistentNotification,
                                backdrop = switchBackdrop,
                                label = "常驻通知保活"
                            )
                        }
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
    healthy: Boolean?
) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 15.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Text(
                status,
                style = MaterialTheme.typography.bodySmall,
                color = when (healthy) {
                    true -> MaterialTheme.colorScheme.onSurfaceVariant
                    false -> MaterialTheme.colorScheme.error
                    null -> MaterialTheme.colorScheme.onSurfaceVariant
                }
            )
        }
        Icon(Icons.Outlined.ChevronRight, null, tint = MaterialTheme.colorScheme.outline)
    }
}

@Composable
private fun SupportSection(
    title: String,
    content: @Composable ColumnScope.() -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(
            title,
            modifier = Modifier.padding(start = 8.dp, bottom = 5.dp),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.labelLarge,
            fontWeight = FontWeight.SemiBold
        )
        content()
    }
}

@Composable
private fun SupportPanel(
    position: SupportGroupPosition,
    onClick: (() -> Unit)? = null,
    content: @Composable () -> Unit
) {
    val shape = when (position) {
        SupportGroupPosition.ONLY -> RoundedCornerShape(18.dp)
        SupportGroupPosition.FIRST -> RoundedCornerShape(
            topStart = 18.dp,
            topEnd = 18.dp,
            bottomStart = 6.dp,
            bottomEnd = 6.dp
        )
        SupportGroupPosition.MIDDLE -> RoundedCornerShape(6.dp)
        SupportGroupPosition.LAST -> RoundedCornerShape(
            topStart = 6.dp,
            topEnd = 6.dp,
            bottomStart = 18.dp,
            bottomEnd = 18.dp
        )
    }
    Card(
        modifier = Modifier.fillMaxWidth().clip(shape)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier),
        shape = shape,
        colors = CardDefaults.cardColors(containerColor = PortalCardBackground),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
    ) {
        content()
    }
}
