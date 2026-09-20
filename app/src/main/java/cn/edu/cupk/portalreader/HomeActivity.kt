package cn.edu.cupk.portalreader

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.School
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

class HomeActivity : PortalActivity() {
    private var notificationVersion by mutableIntStateOf(0)
    private val notificationSettingsLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { notificationVersion++ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        useContinuousSystemBars()
        if (PortalNotificationPreferences.preferences(this)
                .getBoolean(PortalNotificationPreferences.KEY_PERSISTENT_NOTIFICATION, false)
        ) {
            PortalKeepAliveService.setEnabled(this, true)
        }
        setContent {
            PortalTheme {
                val school = remember { SchoolAdapterRepository.load(this) }
                val currentNotificationVersion = notificationVersion
                HomeContent(
                    school = school,
                    onOpenItem = ::openItem,
                    onOpenNotifications = {
                        notificationSettingsLauncher.launch(Intent(this, NotificationSettingsActivity::class.java))
                        @Suppress("DEPRECATION")
                        overridePendingTransition(R.anim.fade_in, R.anim.activity_stay)
                    },
                    onOpenSettings = { startActivity(Intent(this, SettingsActivity::class.java)) },
                    onSessionExpired = ::returnToLogin,
                    notificationVersion = currentNotificationVersion
                )
            }
        }
    }

    private fun openItem(item: PortalItem) {
        val target = if (item.quick) MaterialPortalActivity::class.java else OriginalPortalActivity::class.java
        startActivity(
            Intent(this, target)
                .putExtra(MaterialPortalActivity.EXTRA_TITLE, item.title)
                .putExtra(MaterialPortalActivity.EXTRA_URL, item.url)
        )
    }

    private fun returnToLogin() {
        startActivity(
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        )
        finish()
    }
}

@Composable
private fun HomeContent(
    school: SchoolDefinition,
    onOpenItem: (PortalItem) -> Unit,
    onOpenNotifications: () -> Unit,
    onOpenSettings: () -> Unit,
    onSessionExpired: () -> Unit,
    notificationVersion: Int
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val sessionState by PortalSessionCoordinator.state.collectAsState()
    val notificationPreferences = remember { PortalNotificationPreferences.preferences(context) }
    val enabledNotificationCount = remember(notificationVersion) {
        PortalNotificationPreferences.enabledCount(notificationPreferences)
    }
    var query by remember { mutableStateOf("") }
    val visibleGroups = remember(query, school) {
        if (query.isBlank()) school.groups
        else school.groups.mapNotNull { group ->
            val items = group.items.filter { it.title.contains(query.trim(), ignoreCase = true) }
            if (items.isEmpty()) null else PortalGroup(group.title, items)
        }
    }
    val visibleQuickItems = remember(query, school) {
        school.quickItems.filter { query.isBlank() || it.title.contains(query.trim(), ignoreCase = true) }
    }
    Box(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
    ) {
        Scaffold(
            containerColor = Color.Transparent,
            topBar = {
                Box(
                    Modifier.fillMaxWidth()
                        .background(
                            Brush.verticalGradient(
                                listOf(
                                    MaterialTheme.colorScheme.background,
                                    MaterialTheme.colorScheme.background.copy(alpha = 0f)
                                )
                            )
                        )
                        .statusBarsPadding()
                        .padding(start = 20.dp, end = 12.dp, top = 12.dp, bottom = 14.dp)
                ) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("掌上教务", color = PortalInk, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                            Text(school.name, color = PortalInk.copy(alpha = 0.72f), style = MaterialTheme.typography.labelMedium)
                        }
                        PortalSessionStatus(
                            state = sessionState,
                            onRetry = { PortalSessionCoordinator.validate(context.applicationContext as android.app.Application, force = true) }
                        )
                        IconButton(onClick = onOpenSettings) {
                            Icon(Icons.Outlined.Settings, "设置", tint = PortalInk)
                        }
                    }
                    OutlinedTextField(
                        value = query,
                        onValueChange = { query = it },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                        leadingIcon = { Icon(Icons.Outlined.Search, null) },
                        placeholder = { Text("搜索教务功能") },
                        shape = RoundedCornerShape(18.dp),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedContainerColor = PortalCardBackground.copy(alpha = 0.96f),
                            unfocusedContainerColor = PortalCardBackground.copy(alpha = 0.90f)
                        )
                    )
                }
            }
        }) { padding ->
        LazyColumn(
            modifier = Modifier.padding(padding).fillMaxSize(),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            item {
                Card(
                    modifier = Modifier.clickable(onClick = onOpenNotifications),
                    colors = CardDefaults.cardColors(containerColor = PortalBlueSoft),
                    shape = RoundedCornerShape(22.dp)
                ) {
                    Row(Modifier.fillMaxWidth().padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("通知检测设置", color = PortalInk, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                            Text(
                                if (enabledNotificationCount == 0) "提醒均已关闭 · 点击设置"
                                else "$enabledNotificationCount 项提醒已开启 · 点击设置",
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                style = MaterialTheme.typography.bodySmall
                            )
                        }
                        Icon(Icons.Outlined.Notifications, null, tint = PortalBlue, modifier = Modifier.size(32.dp))
                    }
                }
            }
            if (visibleQuickItems.isNotEmpty()) item { SectionTitle("快捷入口") }
            itemsIndexed(visibleQuickItems.chunked(2)) { _, rowItems ->
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    rowItems.forEach { item -> QuickCard(item, Modifier.weight(1f)) { onOpenItem(item) } }
                    if (rowItems.size == 1) Spacer(Modifier.weight(1f))
                }
            }
            visibleGroups.forEach { group ->
                item { SectionTitle(group.title) }
                item {
                    Card(
                        shape = RoundedCornerShape(18.dp),
                        colors = CardDefaults.cardColors(containerColor = PortalCardBackground)
                    ) {
                        Column {
                            group.items.forEachIndexed { index, item ->
                                PortalRow(item) { onOpenItem(item) }
                                if (index != group.items.lastIndex) HorizontalDivider(Modifier.padding(horizontal = 16.dp))
                            }
                        }
                    }
                }
            }
            item { Spacer(Modifier.height(20.dp)) }
        }
        }
    }
    if (sessionState is PortalSessionState.Expired) {
        AlertDialog(
            onDismissRequest = {},
            title = { Text("登录状态已失效") },
            text = { Text("上次保存的教务登录状态已过期，请重新登录。") },
            confirmButton = { Button(onClick = onSessionExpired) { Text("重新登录") } }
        )
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleMedium,
        color = MaterialTheme.colorScheme.onBackground,
        fontWeight = FontWeight.Bold,
        modifier = Modifier.padding(start = 4.dp, top = 4.dp)
    )
}

@Composable
private fun QuickCard(item: PortalItem, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val icon: ImageVector = when {
        item.title.contains("课表") -> Icons.Outlined.CalendarMonth
        item.title.contains("考试") -> Icons.Outlined.Description
        item.title.contains("成绩") -> Icons.Outlined.School
        else -> Icons.Outlined.Search
    }
    Card(
        modifier = modifier.clickable(onClick = onClick),
        colors = CardDefaults.cardColors(containerColor = PortalBlueSoft),
        shape = RoundedCornerShape(18.dp)
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(icon, null, tint = PortalBlue)
            Text(item.title, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun PortalRow(item: PortalItem, onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(item.title, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
        Icon(Icons.Outlined.ChevronRight, null, tint = MaterialTheme.colorScheme.outline)
    }
}
