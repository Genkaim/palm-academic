package cn.edu.cupk.portalreader

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
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

class SchoolSelectionActivity : PortalActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        useContinuousSystemBars()
        val selectedSchoolId = intent.getStringExtra(EXTRA_SELECTED_SCHOOL_ID)
            ?: SchoolAdapterRepository.activeSchoolId()
        val switchingRequiresLogin = intent.getBooleanExtra(EXTRA_REQUIRES_LOGIN, false)
        setContent {
            PortalTheme {
                SchoolSelectionContent(
                    selectedSchoolId = selectedSchoolId,
                    switchingRequiresLogin = switchingRequiresLogin,
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
    switchingRequiresLogin: Boolean,
    onBack: () -> Unit,
    onSelected: (String) -> Unit
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()
    var schools by remember { mutableStateOf(SchoolAdapterRepository.options(context)) }
    var refreshing by remember { mutableStateOf(false) }
    var statusText by remember { mutableStateOf<String?>(null) }

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
                        enabled = !refreshing,
                        onClick = {
                            refreshing = true
                            statusText = "正在从 GitHub 检查学校适配…"
                            scope.launch {
                                SchoolAdapterRepository.refreshFromGitHub(context)
                                    .onSuccess { result ->
                                        schools = SchoolAdapterRepository.options(context)
                                        statusText = "已更新 ${result.schoolCount} 所学校的适配配置"
                                        Toast.makeText(context, "学校适配已是最新", Toast.LENGTH_SHORT).show()
                                    }
                                    .onFailure { error ->
                                        statusText = error.message ?: "学校适配更新失败"
                                    }
                                refreshing = false
                            }
                        }
                    ) {
                        if (refreshing) {
                            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                        } else {
                            Icon(Icons.Outlined.Refresh, "刷新学校适配")
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
            if (switchingRequiresLogin) {
                item {
                    Text(
                        "切换学校后需要重新登录。",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.padding(horizontal = 4.dp)
                    )
                }
            }
            statusText?.let { message ->
                item {
                    Text(
                        message,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.padding(horizontal = 4.dp)
                    )
                }
            }
            items(schools, key = { it.id }) { school ->
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
    }
}
