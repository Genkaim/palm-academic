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
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.History
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.kyant.backdrop.backdrops.layerBackdrop
import com.kyant.backdrop.backdrops.rememberLayerBackdrop

private data class NotificationSetting(
    val key: String,
    val title: String,
    val description: String
)

private enum class NotificationGroupPosition { ONLY, FIRST, MIDDLE, LAST }

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
                NotificationSection(
                    title = "通知类型",
                    footer = if (!notificationPermissionGranted && enabledKeys.isNotEmpty()) {
                        "系统通知权限尚未开启，开启任一提醒时会再次申请权限。"
                    } else {
                        "关闭的项目仍会正常显示在教务页面中，只是不再发送系统通知。"
                    },
                    footerIsError = !notificationPermissionGranted && enabledKeys.isNotEmpty()
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        settings.forEachIndexed { index, setting ->
                            val checked = setting.key in enabledKeys
                            val position = when {
                                settings.size == 1 -> NotificationGroupPosition.ONLY
                                index == 0 -> NotificationGroupPosition.FIRST
                                index == settings.lastIndex -> NotificationGroupPosition.LAST
                                else -> NotificationGroupPosition.MIDDLE
                            }
                            NotificationTogglePanel(
                                position = position,
                                setting = setting,
                                checked = checked,
                                backdrop = switchBackdrop,
                                onCheckedChange = { enabled ->
                                    enabledKeys = if (enabled) {
                                        enabledKeys + setting.key
                                    } else {
                                        enabledKeys - setting.key
                                    }
                                    preferences.edit().putBoolean(setting.key, enabled).apply()
                                    PortalMonitor.reconcile(context)
                                    if (
                                        enabled && Build.VERSION.SDK_INT >= 33 &&
                                        !notificationPermissionGranted
                                    ) {
                                        permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                                    }
                                }
                            )
                        }
                    }
                }
            }
            item {
                NotificationSection(
                    title = "检查频率",
                    footer = "实际执行时间会受网络状态和系统省电策略影响。"
                ) {
                    NotificationGroupedCard {
                        Column(
                            Modifier.fillMaxWidth().padding(16.dp),
                            verticalArrangement = Arrangement.spacedBy(12.dp)
                        ) {
                            Text("间隔", fontWeight = FontWeight.SemiBold)
                            NotificationIntervalControl(
                                selected = interval,
                                onSelected = { value ->
                                    interval = value
                                    preferences.edit().putLong("interval", value).apply()
                                    if (PortalNotificationPreferences.anyEnabled(preferences)) {
                                        PortalMonitor.schedule(context, value)
                                    }
                                }
                            )
                        }
                    }
                }
            }
            item {
                NotificationSection(title = "记录") {
                    NotificationGroupedCard(
                        modifier = Modifier
                            .clip(RoundedCornerShape(18.dp))
                            .clickable(onClick = onOpenHistory)
                    ) {
                        Row(
                            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 15.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Icon(
                                Icons.Outlined.History,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSurface,
                                modifier = Modifier.size(22.dp)
                            )
                            Spacer(Modifier.size(13.dp))
                            Column(Modifier.weight(1f)) {
                                Text("检查日志", fontWeight = FontWeight.SemiBold)
                                Text(
                                    "查看检测历史与具体变动",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            Icon(
                                Icons.Outlined.ChevronRight,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.outline
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
private fun NotificationSection(
    title: String,
    footer: String? = null,
    footerIsError: Boolean = false,
    content: @Composable ColumnScope.() -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            title,
            modifier = Modifier.padding(start = 8.dp),
            style = MaterialTheme.typography.labelLarge,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        content()
        footer?.let {
            Text(
                it,
                modifier = Modifier.padding(horizontal = 8.dp),
                style = MaterialTheme.typography.bodySmall,
                color = if (footerIsError) {
                    MaterialTheme.colorScheme.error
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                }
            )
        }
    }
}

@Composable
private fun NotificationGroupedCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit
) {
    Card(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = PortalCardBackground),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
    ) {
        Column(content = content)
    }
}

@Composable
private fun NotificationTogglePanel(
    position: NotificationGroupPosition,
    setting: NotificationSetting,
    checked: Boolean,
    backdrop: com.kyant.backdrop.Backdrop,
    onCheckedChange: (Boolean) -> Unit
) {
    val shape = when (position) {
        NotificationGroupPosition.ONLY -> RoundedCornerShape(18.dp)
        NotificationGroupPosition.FIRST -> RoundedCornerShape(
            topStart = 18.dp,
            topEnd = 18.dp,
            bottomStart = 6.dp,
            bottomEnd = 6.dp
        )
        NotificationGroupPosition.MIDDLE -> RoundedCornerShape(6.dp)
        NotificationGroupPosition.LAST -> RoundedCornerShape(
            topStart = 6.dp,
            topEnd = 6.dp,
            bottomStart = 18.dp,
            bottomEnd = 18.dp
        )
    }
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = shape,
        colors = CardDefaults.cardColors(containerColor = PortalCardBackground),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(setting.title, fontWeight = FontWeight.SemiBold)
                Text(
                    setting.description,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Spacer(Modifier.size(14.dp))
            PortalGlassSwitch(
                checked = checked,
                backdrop = backdrop,
                label = setting.title,
                onCheckedChange = onCheckedChange
            )
        }
    }
}

@Composable
private fun NotificationIntervalControl(
    selected: Long,
    onSelected: (Long) -> Unit
) {
    val entries = listOf(15L, 30L, 60L)
    val selectedIndex = entries.indexOf(selected).coerceAtLeast(0)
    BoxWithConstraints(
        modifier = Modifier
            .fillMaxWidth()
            .height(40.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(3.dp)
    ) {
        val segmentWidth = maxWidth / entries.size
        val indicatorOffset by animateDpAsState(
            targetValue = segmentWidth * selectedIndex,
            animationSpec = tween(durationMillis = 220, easing = FastOutSlowInEasing),
            label = "notification-interval-indicator"
        )
        Box(Modifier.matchParentSize()) {
            Box(
                Modifier
                    .offset(x = indicatorOffset)
                    .width(segmentWidth)
                    .fillMaxHeight()
                    .clip(RoundedCornerShape(10.dp))
                    .background(PortalCardBackground)
            )
        }
        Row(Modifier.fillMaxWidth()) {
            entries.forEach { value ->
                val isSelected = value == selected
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(10.dp))
                        .clickable(
                            interactionSource = null,
                            indication = null,
                            onClick = { onSelected(value) }
                        )
                        .padding(vertical = 8.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        "$value 分钟",
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                        color = if (isSelected) {
                            MaterialTheme.colorScheme.onSurface
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        }
                    )
                }
            }
        }
    }
}
