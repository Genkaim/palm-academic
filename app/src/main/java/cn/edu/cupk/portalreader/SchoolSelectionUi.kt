package cn.edu.cupk.portalreader

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
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
    var refreshing by remember { mutableStateOf(false) }
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
            TopAppBar(
                title = { Text("选择学校") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Outlined.ArrowBack, "返回")
                    }
                },
                actions = {
                    IconButton(
                        modifier = Modifier.padding(end = 8.dp),
                        enabled = !refreshing,
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
                    ) {
                        Box(Modifier.size(24.dp), contentAlignment = Alignment.Center) {
                            if (refreshing) {
                                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                            } else {
                                Icon(Icons.Outlined.Refresh, "刷新学校适配")
                            }
                        }
                    }
                }
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier.padding(padding).fillMaxSize(),
            contentPadding = PaddingValues(16.dp),
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
                        modifier = Modifier.fillMaxWidth().clickable { onSelected(school.id) },
                        shape = RoundedCornerShape(18.dp),
                        colors = CardDefaults.cardColors(containerColor = PortalCardBackground)
                    ) {
                        Row(
                            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            RadioButton(
                                selected = school.id == selectedSchoolId,
                                onClick = { onSelected(school.id) }
                            )
                            Spacer(Modifier.size(10.dp))
                            Column(Modifier.weight(1f)) {
                                Text(
                                    school.name,
                                    fontWeight = if (school.id == selectedSchoolId) {
                                        FontWeight.SemiBold
                                    } else FontWeight.Normal
                                )
                                Text(
                                    school.id,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }
                }
            }
            item {
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
        }
    }
}
