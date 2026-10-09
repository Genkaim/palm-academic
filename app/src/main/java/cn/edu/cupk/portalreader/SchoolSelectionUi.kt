package cn.edu.cupk.portalreader

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.automirrored.outlined.InsertDriveFile
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.nio.charset.Charset
import java.text.Collator
import java.util.Locale

private val schoolNameCollator: Collator = Collator.getInstance(Locale.CHINA)
private val gbkCharset: Charset = Charset.forName("GBK")
private val pinyinInitialBoundaries = listOf(
    -20319 to 'A', -20284 to 'B', -19776 to 'C', -19219 to 'D', -18711 to 'E',
    -18527 to 'F', -18240 to 'G', -17923 to 'H', -17418 to 'J', -16475 to 'K',
    -16213 to 'L', -15641 to 'M', -15166 to 'N', -14923 to 'O', -14915 to 'P',
    -14631 to 'Q', -14150 to 'R', -14091 to 'S', -13319 to 'T', -12839 to 'W',
    -12557 to 'X', -11848 to 'Y', -11056 to 'Z'
)
private const val ADAPTER_GUIDE_URL =
    "https://github.com/Genkaim/palm-academic/blob/main/docs/ADAPTER_GUIDE.md"

private fun schoolInitial(name: String): String {
    val first = name.trim().firstOrNull() ?: return "#"
    val latinInitial = first.uppercaseChar().takeIf { it in 'A'..'Z' }
    if (latinInitial != null) return latinInitial.toString()
    val bytes = first.toString().toByteArray(gbkCharset)
    if (bytes.size < 2) return "#"
    val code = bytes[0].toInt() * 256 + bytes[1].toInt() + 256
    return pinyinInitialBoundaries.lastOrNull { code >= it.first }?.second?.toString() ?: "#"
}

class SchoolSelectionActivity : PortalActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        useContinuousSystemBars()
        val selectedSchoolId = intent.getStringExtra(EXTRA_SELECTED_SCHOOL_ID)
            ?: SchoolAdapterRepository.activeSchoolId()
        setContent {
            PortalTheme {
                SchoolSelectionContent(
                    selectedSchoolId = selectedSchoolId,
                    onBack = { finish() },
                    onSelected = { schoolId ->
                        setResult(
                            Activity.RESULT_OK,
                            Intent().putExtra(EXTRA_RESULT_SCHOOL_ID, schoolId)
                        )
                        finish()
                    }
                )
            }
        }
    }

    companion object {
        const val EXTRA_SELECTED_SCHOOL_ID = "selected_school_id"
        const val EXTRA_REQUIRES_LOGIN = "requires_login"
        const val EXTRA_RESULT_SCHOOL_ID = "result_school_id"
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SchoolSelectionContent(
    selectedSchoolId: String,
    onBack: () -> Unit,
    onSelected: (String) -> Unit
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()
    var schools by remember { mutableStateOf(SchoolAdapterRepository.options(context)) }
    var currentSelectedId by remember { mutableStateOf(selectedSchoolId) }
    var refreshing by remember { mutableStateOf(false) }
    var showingImport by remember { mutableStateOf(false) }
    var importing by remember { mutableStateOf(false) }
    var definitionUri by remember { mutableStateOf<Uri?>(null) }
    var adapterUri by remember { mutableStateOf<Uri?>(null) }
    var info by remember { mutableStateOf<SchoolAuthorInfo?>(null) }
    var pendingDelete by remember { mutableStateOf<SchoolOption?>(null) }
    val definitionPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { definitionUri = it }
    val adapterPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { adapterUri = it }
    val groupedSchools = remember(schools) {
        schools.sortedWith { left, right ->
            schoolNameCollator.compare(left.name, right.name).takeIf { it != 0 }
                ?: left.id.compareTo(right.id)
        }
            .groupBy { schoolInitial(it.name) }
            .toSortedMap(compareBy<String> { it == "#" }.thenBy { it })
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            PortalGradientTopAppBar(
                title = { Text("选择学校") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Outlined.ArrowBack, "返回")
                    }
                },
                actions = {
                    PortalTopBarRefreshButton(
                        refreshing = refreshing,
                        onClick = {
                            refreshing = true
                            scope.launch {
                                val message = SchoolAdapterRepository.refreshFromGitHub(context)
                                    .fold(
                                        onSuccess = { result ->
                                            schools = SchoolAdapterRepository.options(context)
                                            "已更新 ${result.schoolCount} 所学校"
                                        },
                                        onFailure = { "更新失败，请检查网络" }
                                    )
                                refreshing = false
                                Toast.makeText(context, message, Toast.LENGTH_SHORT).show()
                            }
                        }
                    )
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
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            groupedSchools.forEach { (initial, group) ->
                item(key = "school-initial-$initial") {
                    Text(
                        text = initial,
                        color = MaterialTheme.colorScheme.primary,
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(start = 8.dp, top = 6.dp, bottom = 2.dp)
                    )
                }
                items(group, key = { it.id }) { school ->
                    Card(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(18.dp))
                            .clickable { onSelected(school.id) },
                        shape = RoundedCornerShape(18.dp),
                        colors = CardDefaults.cardColors(containerColor = PortalCardBackground)
                    ) {
                        Row(
                            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            RadioButton(
                                selected = school.id == currentSelectedId,
                                onClick = { onSelected(school.id) }
                            )
                            Spacer(Modifier.size(10.dp))
                            Column(Modifier.weight(1f)) {
                                Text(
                                    school.name,
                                    fontWeight = if (school.id == currentSelectedId) {
                                        FontWeight.SemiBold
                                    } else FontWeight.Normal
                                )
                                Text(
                                    school.id,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            IconButton(onClick = {
                                info = SchoolAdapterRepository.authorInfo(context, school.id)
                            }) {
                                Icon(Icons.Outlined.Info, "查看作者和联系方式")
                            }
                            if (school.isImported) {
                                IconButton(onClick = { pendingDelete = school }) {
                                    Icon(
                                        Icons.Outlined.Delete,
                                        "删除本地规则",
                                        tint = MaterialTheme.colorScheme.error
                                    )
                                }
                            }
                        }
                    }
                }
            }
            item(key = "guide-link") {
                Row(
                    modifier = Modifier.fillMaxWidth()
                        .padding(horizontal = 8.dp, vertical = 18.dp),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        "没有找到你的学校？",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall
                    )
                    Text(
                        text = "查看适配指引",
                        color = MaterialTheme.colorScheme.primary,
                        style = MaterialTheme.typography.bodySmall.copy(
                            textDecoration = androidx.compose.ui.text.style.TextDecoration.Underline
                        ),
                        modifier = Modifier.clickable {
                            runCatching {
                                context.startActivity(
                                    Intent(Intent.ACTION_VIEW, Uri.parse(ADAPTER_GUIDE_URL))
                                )
                            }
                        }
                    )
                }
            }
            // The local-rule import lives at the very bottom of the school list rather than in
            // the top bar: it is a rare, secondary action and reads as "add your own school"
            // after the built-in list and the guide link.
            item(key = "import-local") {
                OutlinedButton(
                    onClick = { showingImport = true },
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 8.dp)
                        .height(52.dp),
                    shape = RoundedCornerShape(18.dp),
                    border = androidx.compose.foundation.BorderStroke(
                        1.dp,
                        MaterialTheme.colorScheme.outline
                    )
                ) {
                    Icon(Icons.Outlined.Add, null)
                    Spacer(Modifier.size(8.dp))
                    Text("导入本地规则", fontWeight = FontWeight.Medium)
                }
            }
        }
    }

    if (showingImport) {
        ModalBottomSheet(onDismissRequest = { if (!importing) showingImport = false }) {
            Column(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Text("导入本地规则", style = MaterialTheme.typography.titleLarge)
                Text(
                    "依次选择学校定义 JSON 和对应的适配器 JS。导入内容仅保存在本机，不会被云端刷新覆盖。",
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                LocalRuleFileButton(
                    title = "学校定义 JSON",
                    fileName = definitionUri?.let { displayName(context, it) },
                    onClick = { definitionPicker.launch(arrayOf("application/json", "text/plain")) }
                )
                LocalRuleFileButton(
                    title = "适配器 JavaScript",
                    fileName = adapterUri?.let { displayName(context, it) },
                    onClick = {
                        adapterPicker.launch(
                            arrayOf("text/javascript", "application/javascript", "text/plain")
                        )
                    }
                )
                Button(
                    onClick = {
                        val json = definitionUri ?: return@Button
                        val script = adapterUri ?: return@Button
                        importing = true
                        scope.launch {
                            val result = runCatching {
                                withContext(Dispatchers.IO) {
                                    val definitionText = context.contentResolver.openInputStream(json)
                                        ?.bufferedReader()?.use { it.readText() }
                                        ?: error("无法读取规则 JSON")
                                    val adapterText = context.contentResolver.openInputStream(script)
                                        ?.bufferedReader()?.use { it.readText() }
                                        ?: error("无法读取适配器 JS")
                                    SchoolAdapterRepository.importLocalSchool(
                                        context.applicationContext,
                                        definitionText,
                                        adapterText
                                    )
                                }
                            }
                            importing = false
                            result.onSuccess { imported ->
                                schools = SchoolAdapterRepository.options(context)
                                definitionUri = null
                                adapterUri = null
                                showingImport = false
                                Toast.makeText(
                                    context,
                                    "已导入 ${imported.name}",
                                    Toast.LENGTH_SHORT
                                ).show()
                            }.onFailure { error ->
                                Toast.makeText(
                                    context,
                                    error.message ?: "导入失败，请检查两个文件",
                                    Toast.LENGTH_LONG
                                ).show()
                            }
                        }
                    },
                    enabled = definitionUri != null && adapterUri != null && !importing,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(if (importing) "正在校验…" else "校验并导入")
                }
                Spacer(Modifier.size(12.dp))
            }
        }
    }

    info?.let { author ->
        AlertDialog(
            onDismissRequest = { info = null },
            icon = { Icon(Icons.Outlined.Info, null) },
            title = { Text(author.schoolName) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("作者：${author.authorName}")
                    Text("联系方式：${author.contact}")
                    Text(if (author.isImported) "来源：本地导入" else "来源：内置 / 云端")
                }
            },
            confirmButton = { TextButton(onClick = { info = null }) { Text("完成") } }
        )
    }

    pendingDelete?.let { school ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("删除本地规则？") },
            text = { Text("将从本机删除“${school.name}”的 JSON 与 JS 文件，此操作不会影响云端规则。") },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text("取消") }
            },
            confirmButton = {
                TextButton(onClick = {
                    runCatching {
                        currentSelectedId = SchoolAdapterRepository.deleteLocalSchool(context, school.id)
                        schools = SchoolAdapterRepository.options(context)
                    }.onSuccess {
                        Toast.makeText(context, "已删除本地规则", Toast.LENGTH_SHORT).show()
                    }.onFailure {
                        Toast.makeText(context, it.message ?: "删除失败", Toast.LENGTH_SHORT).show()
                    }
                    pendingDelete = null
                }) { Text("删除", color = MaterialTheme.colorScheme.error) }
            }
        )
    }
}

@Composable
private fun LocalRuleFileButton(
    title: String,
    fileName: String?,
    onClick: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(Icons.AutoMirrored.Outlined.InsertDriveFile, null)
            Spacer(Modifier.size(12.dp))
            Column(Modifier.weight(1f)) {
                Text(title, fontWeight = FontWeight.Medium)
                Text(
                    fileName ?: "点按选择文件",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

private fun displayName(context: android.content.Context, uri: Uri): String {
    context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
        ?.use { cursor ->
            if (cursor.moveToFirst()) return cursor.getString(0)
        }
    return uri.lastPathSegment ?: "已选择文件"
}
