package cn.edu.cupk.portalreader

import android.os.Bundle
import android.widget.Toast
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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.DeleteSweep
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.FileDownload
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

class NotificationHistoryActivity : PortalActivity() {
    private var pendingExportContent: String? = null
    private val createLogDocument = registerForActivityResult(
        ActivityResultContracts.CreateDocument("text/plain")
    ) { uri ->
        val content = pendingExportContent
        pendingExportContent = null
        if (uri == null || content == null) return@registerForActivityResult
        runCatching {
            contentResolver.openOutputStream(uri, "w")?.bufferedWriter(Charsets.UTF_8)?.use {
                it.write(content)
            } ?: error("无法创建日志文件")
        }.onSuccess {
            Toast.makeText(this, "日志已导出", Toast.LENGTH_SHORT).show()
        }.onFailure {
            Toast.makeText(this, it.message ?: "导出失败", Toast.LENGTH_LONG).show()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        useContinuousSystemBars()
        setContent {
            PortalTheme {
                NotificationHistoryContent(
                    onBack = ::finishPortalActivity,
                    onExport = ::exportHistory
                )
            }
        }
    }

    private fun exportHistory(entries: List<PortalPollHistoryEntry>) {
        if (entries.isEmpty()) return
        pendingExportContent = historyExportText(entries)
        val timestamp = Instant.now().atZone(ZoneId.systemDefault()).format(historyFileTimeFormatter)
        createLogDocument.launch("掌上教务检查日志-$timestamp.txt")
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NotificationHistoryContent(
    onBack: () -> Unit,
    onExport: (List<PortalPollHistoryEntry>) -> Unit
) {
    val context = LocalContext.current
    var entries by remember { mutableStateOf(PortalPollHistory.read(context)) }
    var expandedRows by remember { mutableStateOf(emptySet<Int>()) }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            PortalGradientTopAppBar(
                title = { Text("检查日志") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Outlined.ArrowBack, "返回")
                    }
                },
                actions = {
                    IconButton(
                        enabled = entries.isNotEmpty(),
                        onClick = {
                            PortalPollHistory.clear(context)
                            entries = emptyList()
                            expandedRows = emptySet()
                        }
                    ) {
                        Icon(Icons.Outlined.DeleteSweep, "清空历史")
                    }
                    IconButton(
                        enabled = entries.isNotEmpty(),
                        onClick = { onExport(entries) }
                    ) {
                        Icon(
                            Icons.Outlined.FileDownload,
                            "导出 TXT 日志"
                        )
                    }
                }
            )
        }
    ) { padding ->
        if (entries.isEmpty()) {
            Column(
                modifier = Modifier.padding(padding).fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                Text("暂无检查记录", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(
                    start = 16.dp,
                    top = (padding.calculateTopPadding() - PortalTopFadeDepth).coerceAtLeast(0.dp) + 16.dp,
                    end = 16.dp,
                    bottom = padding.calculateBottomPadding() + 16.dp
                ),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                itemsIndexed(entries, key = { index, entry -> "${entry.timestamp}-$index" }) { index, entry ->
                    val expanded = index in expandedRows
                    HistoryEntryCard(
                        entry = entry,
                        expanded = expanded,
                        onToggle = {
                            expandedRows = if (expanded) expandedRows - index else expandedRows + index
                        }
                    )
                }
            }
        }
    }
}

@Composable
private fun HistoryEntryCard(
    entry: PortalPollHistoryEntry,
    expanded: Boolean,
    onToggle: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .clickable(onClick = onToggle),
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = PortalCardBackground)
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(formatHistoryTime(entry.timestamp), fontWeight = FontWeight.SemiBold)
                    Text(
                        entry.status,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Text(
                    if (entry.notificationTriggered) "已触发通知" else "未触发通知",
                    style = MaterialTheme.typography.labelMedium,
                    color = if (entry.notificationTriggered) {
                        MaterialTheme.colorScheme.primary
                    } else MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(Modifier.size(4.dp))
                Icon(
                    if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,
                    if (expanded) "收起" else "展开",
                    tint = MaterialTheme.colorScheme.outline
                )
            }
            if (expanded) {
                HorizontalDivider()
                entry.details.forEachIndexed { index, detail ->
                    if (index > 0) HorizontalDivider(Modifier.padding(vertical = 4.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                detail.category,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.weight(1f)
                            )
                            if (detail.notificationTriggered) {
                                Text(
                                    "已通知",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.primary
                                )
                            }
                        }
                        DetailLine("结果", detail.summary)
                        DetailLine("检测到变化", if (detail.changed) "是" else "否")
                        detail.notificationEnabled?.let {
                            DetailLine("该项提醒", if (it) "已开启" else "未开启")
                        }
                        DetailLine(
                            "通知触发",
                            if (detail.notificationTriggered) "已成功发出" else "未发出"
                        )
                        detail.responseCode?.takeIf { it !in 200..299 }?.let {
                            DetailLine("HTTP 状态", it.toString())
                        }
                        if (detail.difference.isNotBlank()) {
                            DetailBlock("数据明细", detail.difference)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun DetailLine(label: String, value: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            "$label：",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(value, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun DetailBlock(label: String, value: String, monospace: Boolean = false) {
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(
            "$label：",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            value,
            style = MaterialTheme.typography.bodySmall.copy(
                fontFamily = if (monospace) FontFamily.Monospace else FontFamily.Default
            ),
            color = MaterialTheme.colorScheme.onSurface
        )
    }
}

private val historyTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")
private val historyFileTimeFormatter = DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss")

private fun formatHistoryTime(timestamp: Long): String = Instant.ofEpochMilli(timestamp)
    .atZone(ZoneId.systemDefault())
    .format(historyTimeFormatter)

internal fun historyExportText(entries: List<PortalPollHistoryEntry>): String = buildString {
    appendLine("掌上教务后台检查日志")
    entries.forEachIndexed { entryIndex, entry ->
        if (entryIndex > 0) appendLine()
        appendLine("检查时间：${formatHistoryTime(entry.timestamp)}")
        appendLine("检查状态：${entry.status}")
        entry.details.forEach { detail ->
            appendLine()
            appendLine("项目：${detail.category}")
            appendLine("结果：${detail.summary}")
            appendLine("检测到变化：${if (detail.changed) "是" else "否"}")
            detail.notificationEnabled?.let {
                appendLine("该项提醒：${if (it) "已开启" else "未开启"}")
            }
            appendLine(
                "通知触发：${if (detail.notificationTriggered) "已成功发出" else "未发出"}"
            )
            detail.responseCode?.takeIf { it !in 200..299 }?.let {
                appendLine("HTTP 状态：$it")
            }
            if (detail.difference.isNotBlank()) {
                appendLine("数据明细：")
                appendLine(detail.difference)
            }
        }
        appendLine("---")
    }
}.trimEnd()
