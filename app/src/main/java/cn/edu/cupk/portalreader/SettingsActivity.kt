package cn.edu.cupk.portalreader

import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.compose.animation.animateColorAsState
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
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.BlurOn
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.Palette
import androidx.compose.material.icons.outlined.School
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material.icons.outlined.Update
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import com.kyant.backdrop.backdrops.rememberCanvasBackdrop

private enum class GroupPosition { ONLY, FIRST, MIDDLE, LAST }

@Composable
internal fun SettingsContent(
    onNotifications: () -> Unit,
    onBackgroundSupport: () -> Unit,
    onOpenSchoolSelection: () -> Unit,
    onLogout: () -> Unit,
    modifier: Modifier = Modifier,
    topPadding: androidx.compose.ui.unit.Dp = 12.dp,
    bottomPadding: androidx.compose.ui.unit.Dp = 32.dp
) {
    val context = LocalContext.current
    val selectedSchoolName = remember { SchoolAdapterRepository.activeName(context) }
    var confirmLogout by remember { mutableStateOf(false) }
    var checkingUpdate by remember { mutableStateOf(false) }
    var availableRelease by remember { mutableStateOf<GitHubRelease?>(null) }
    val glassEnabled = PortalThemePreferences.glassEnabled
    val controlBackground = PortalCardBackground
    val controlBackdrop = rememberCanvasBackdrop { drawRect(controlBackground) }
    val scope = rememberCoroutineScope()
    val themeMode = PortalThemePreferences.mode

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(
            start = 16.dp,
            top = topPadding,
            end = 16.dp,
            bottom = bottomPadding
        ),
        verticalArrangement = Arrangement.spacedBy(24.dp)
    ) {
            item {
                SettingsSection(title = "外观") {
                    SettingsPanel(GroupPosition.FIRST) {
                        Column(
                            Modifier.fillMaxWidth().padding(16.dp),
                            verticalArrangement = Arrangement.spacedBy(14.dp)
                        ) {
                            SettingsTitleRow(Icons.Outlined.Palette, "显示模式", "选择界面的明暗外观")
                            AppleSegmentedControl(
                                entries = PortalThemeMode.entries,
                                selected = themeMode,
                                label = PortalThemeMode::displayName,
                                onSelected = { PortalThemePreferences.set(context, it) }
                            )
                        }
                    }
                    SettingsPanel(GroupPosition.LAST) {
                        Row(
                            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Box(Modifier.size(34.dp), contentAlignment = Alignment.Center) {
                                Icon(
                                    Icons.Outlined.BlurOn,
                                    contentDescription = null,
                                    modifier = Modifier.size(22.dp),
                                    tint = MaterialTheme.colorScheme.onSurface
                                )
                            }
                            Spacer(Modifier.size(13.dp))
                            Column(Modifier.weight(1f)) {
                                Text("液态玻璃", fontWeight = FontWeight.SemiBold)
                                Text(
                                    if (glassEnabled) "折射与模糊效果已开启" else "使用普通半透明控件",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            PortalGlassSwitch(
                                checked = glassEnabled,
                                onCheckedChange = {
                                    PortalThemePreferences.setGlassEnabled(context, it)
                                },
                                backdrop = controlBackdrop,
                                glassEnabled = glassEnabled,
                                label = "液态玻璃"
                            )
                        }
                    }
                }
            }

            item {
                SettingsSection(title = "教务") {
                    SettingsNavigationPanel(
                        position = GroupPosition.FIRST,
                        title = "学校",
                        description = selectedSchoolName,
                        icon = Icons.Outlined.School,
                        onClick = onOpenSchoolSelection
                    )
                    SettingsNavigationPanel(
                        position = GroupPosition.LAST,
                        title = "变动通知",
                        description = "课表、成绩与考试提醒",
                        icon = Icons.Outlined.Notifications,
                        onClick = onNotifications
                    )
                }
            }

            item {
                SettingsSection(title = "应用") {
                    SettingsNavigationPanel(
                        position = GroupPosition.FIRST,
                        title = "后台运行",
                        description = "自启动、电池优化与后台限制",
                        icon = Icons.Outlined.Sync,
                        onClick = onBackgroundSupport
                    )
                    SettingsNavigationPanel(
                        position = GroupPosition.LAST,
                        title = "软件更新",
                        description = if (checkingUpdate) "正在检查更新…" else "当前版本 ${BuildConfig.VERSION_NAME}",
                        icon = Icons.Outlined.Update,
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
                                        .onFailure {
                                            Toast.makeText(context, "检查失败，请注意网络环境", Toast.LENGTH_SHORT).show()
                                        }
                                    checkingUpdate = false
                                }
                            }
                        }
                    )
                }
            }

            item {
                SettingsSection(title = "账户") {
                    SettingsPanel(
                        position = GroupPosition.ONLY,
                        onClick = { confirmLogout = true }
                    ) {
                        Text(
                            "退出登录",
                            modifier = Modifier.fillMaxWidth().padding(17.dp),
                            color = MaterialTheme.colorScheme.error,
                            fontWeight = FontWeight.SemiBold
                        )
                    }
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
                TextButton(
                    onClick = { confirmLogout = false },
                    colors = ButtonDefaults.textButtonColors(
                        contentColor = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                ) { Text("取消") }
            }
        )
    }
    availableRelease?.let { release ->
        AlertDialog(
            onDismissRequest = { availableRelease = null },
            title = { Text("发现新版本 ${release.tagName}") },
            text = {
                Text(release.notes.ifBlank { "新版本已发布，可前往 GitHub 下载更新。" }.take(2000))
            },
            confirmButton = {
                Button(onClick = {
                    availableRelease = null
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(release.apkUrl ?: release.pageUrl)))
                }) { Text(if (release.apkUrl != null) "下载 APK" else "查看 Release") }
            },
            dismissButton = {
                OutlinedButton(onClick = { availableRelease = null }) { Text("稍后") }
            }
        )
    }
}

@Composable
private fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
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
private fun SettingsPanel(
    position: GroupPosition,
    onClick: (() -> Unit)? = null,
    content: @Composable () -> Unit
) {
    val shape = when (position) {
        GroupPosition.ONLY -> RoundedCornerShape(18.dp)
        GroupPosition.FIRST -> RoundedCornerShape(topStart = 18.dp, topEnd = 18.dp, bottomStart = 6.dp, bottomEnd = 6.dp)
        GroupPosition.MIDDLE -> RoundedCornerShape(6.dp)
        GroupPosition.LAST -> RoundedCornerShape(topStart = 6.dp, topEnd = 6.dp, bottomStart = 18.dp, bottomEnd = 18.dp)
    }
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier),
        shape = shape,
        colors = CardDefaults.cardColors(containerColor = PortalCardBackground),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
    ) {
        content()
    }
}

@Composable
private fun SettingsNavigationPanel(
    position: GroupPosition,
    title: String,
    description: String,
    icon: ImageVector,
    onClick: () -> Unit
) {
    SettingsPanel(position = position, onClick = onClick) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 15.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier.size(34.dp),
                contentAlignment = Alignment.Center
            ) {
                Icon(icon, null, tint = MaterialTheme.colorScheme.onSurface, modifier = Modifier.size(22.dp))
            }
            Spacer(Modifier.size(13.dp))
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

@Composable
private fun SettingsTitleRow(icon: ImageVector, title: String, description: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier = Modifier.size(34.dp),
            contentAlignment = Alignment.Center
        ) {
            Icon(icon, null, tint = MaterialTheme.colorScheme.onSurface, modifier = Modifier.size(22.dp))
        }
        Spacer(Modifier.size(13.dp))
        Column {
            Text(title, fontWeight = FontWeight.SemiBold)
            Text(
                description,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun <T> AppleSegmentedControl(
    entries: List<T>,
    selected: T,
    label: (T) -> String,
    onSelected: (T) -> Unit
) {
    if (entries.isEmpty()) return
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
            animationSpec = tween(220, easing = FastOutSlowInEasing),
            label = "appearance-indicator"
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
            entries.forEach { entry ->
                val isSelected = entry == selected
                val textColor by animateColorAsState(
                    targetValue = if (isSelected) PortalInk else MaterialTheme.colorScheme.onSurfaceVariant,
                    animationSpec = tween(180),
                    label = "appearance-text-color"
                )
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(10.dp))
                        .clickable(
                            interactionSource = null,
                            indication = null,
                            onClick = { onSelected(entry) }
                        )
                        .padding(vertical = 8.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        label(entry),
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                        color = textColor
                    )
                }
            }
        }
    }
}
