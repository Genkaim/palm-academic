package cn.edu.cupk.portalreader

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.FileDownload
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

private data class ExportDocument(val fileName: String, val content: String)
private const val FEATURE_HINT_PREFERENCES = "feature_hints"
private const val KEY_SCHEDULE_EXPORT_HINT_SHOWN = "schedule_export_hint_shown_v1"

private enum class MaterialContentStage { AUTHENTICATING, AUTH_UNAVAILABLE, FETCHING, CONTENT, ERROR, SESSION_EXPIRED }

class MaterialPortalActivity : PortalActivity() {
    private var pendingExport: ExportDocument? = null
    private var fallbackUnitTimes: Map<String, Pair<String, String>> = emptyMap()
    private val createDocument = registerForActivityResult(ActivityResultContracts.CreateDocument("*/*")) { uri ->
        val document = pendingExport
        if (uri != null && document != null) {
            runCatching {
                contentResolver.openOutputStream(uri)?.bufferedWriter()?.use { it.write(document.content) }
                    ?: error("无法创建文件")
            }.onSuccess {
                Toast.makeText(this, "课表已导出", Toast.LENGTH_SHORT).show()
            }.onFailure {
                Toast.makeText(this, it.message ?: "导出失败", Toast.LENGTH_LONG).show()
            }
        }
        pendingExport = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        useContinuousSystemBars()
        val requestedTitle = intent.getStringExtra(EXTRA_TITLE).orEmpty()
        val requestedUrl = intent.getStringExtra(EXTRA_URL).orEmpty()
        if (!requestedUrl.startsWith("https://")) {
            finish()
            return
        }
        val school = SchoolAdapterRepository.load(this)
        fallbackUnitTimes = school.fallbackUnitTimes
        val script = SchoolAdapterRepository.readAdapterScript(this, school.adapterAsset)
        setContent {
            PortalTheme {
                var sessionExpired by remember { mutableStateOf(false) }
                MaterialPortalContent(
                    requestedTitle = requestedTitle,
                    url = requestedUrl,
                    adapterScript = script,
                    schoolConfigJson = school.readerConfigJson,
                    onBack = { finish() },
                    onOpenLink = { title, url -> openLink(title, url) },
                    onExport = ::exportSchedule,
                    onSessionExpired = { sessionExpired = true }
                )
                if (sessionExpired) {
                    AlertDialog(
                        onDismissRequest = {},
                        title = { Text("登录状态已失效") },
                        text = { Text("教务系统登录状态已过期或账号凭据已变更，请重新登录。") },
                        confirmButton = {
                            Button(onClick = {
                                PortalSessionCoordinator.clear()
                                PortalHttp.clearSession { runOnUiThread(::returnToLogin) }
                            }) { Text("重新登录") }
                        }
                    )
                }
            }
        }
    }

    private fun exportSchedule(page: MaterialPage, format: String) {
        val schedule = page.sections.filterIsInstance<MaterialSection.Schedule>().firstOrNull() ?: return
        val document = when (format) {
            "ics" -> ExportDocument(
                "${schedule.title.ifBlank { "课表" }}.ics",
                scheduleToIcs(schedule, fallbackUnitTimes)
            )
            "json" -> ExportDocument("${schedule.title.ifBlank { "课表" }}.json", scheduleToJson(schedule))
            else -> ExportDocument(
                "WakeUp课程表-${schedule.title.ifBlank { "课表" }}.csv",
                scheduleToCsv(schedule)
            )
        }
        pendingExport = document
        createDocument.launch(document.fileName)
    }

    private fun openLink(title: String, url: String) {
        startActivity(
            Intent(this, OriginalPortalActivity::class.java)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_URL, url)
        )
    }

    private fun returnToLogin() {
        startActivity(
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        )
        finish()
    }

    companion object {
        const val EXTRA_TITLE = "page_title"
        const val EXTRA_URL = "page_url"
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MaterialPortalContent(
    requestedTitle: String,
    url: String,
    adapterScript: String,
    schoolConfigJson: String,
    onBack: () -> Unit,
    onOpenLink: (String, String) -> Unit,
    onExport: (MaterialPage, String) -> Unit,
    onSessionExpired: () -> Unit
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val sessionState by PortalSessionCoordinator.state.collectAsState()
    val featureHintPreferences = remember {
        context.getSharedPreferences(FEATURE_HINT_PREFERENCES, android.content.Context.MODE_PRIVATE)
    }
    var page by remember(url) { mutableStateOf(MaterialPageCache.load(context, url)) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var refreshToken by remember { mutableIntStateOf(0) }
    var actionToken by remember { mutableIntStateOf(0) }
    var readerAction by remember { mutableStateOf<MaterialReaderAction?>(null) }
    var showExportHint by remember { mutableStateOf(false) }
    var exportHintTriggered by remember { mutableStateOf(false) }
    val scheduleAvailable = page?.sections?.any { it is MaterialSection.Schedule } == true
    LaunchedEffect(sessionState) {
        if (sessionState is PortalSessionState.Expired || sessionState is PortalSessionState.NoSession) {
            onSessionExpired()
        }
    }
    LaunchedEffect(scheduleAvailable) {
        if (
            scheduleAvailable &&
            !exportHintTriggered &&
            !featureHintPreferences.getBoolean(KEY_SCHEDULE_EXPORT_HINT_SHOWN, false)
        ) {
            showExportHint = true
            exportHintTriggered = true
            // Set the flag only after the hint has actually been triggered on a schedule page.
            featureHintPreferences.edit().putBoolean(KEY_SCHEDULE_EXPORT_HINT_SHOWN, true).apply()
        }
    }
    val performAction: (String, String) -> Unit = { id, value ->
        actionToken++
        loading = true
        readerAction = MaterialReaderAction(id, value, actionToken)
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(page?.title?.ifBlank { requestedTitle } ?: requestedTitle, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "返回") } },
                actions = {
                    page?.takeIf { current -> current.sections.any { it is MaterialSection.Schedule } }?.let { current ->
                        ExportMenu(
                            showHint = showExportHint,
                            onHintDismissed = { showExportHint = false },
                            onExport = { format -> onExport(current, format) }
                        )
                    }
                    IconButton(onClick = {
                        error = null
                        loading = true
                        readerAction = null
                        refreshToken++
                    }) {
                        Icon(Icons.Outlined.Refresh, "刷新")
                    }
                }
            )
        }
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            if (
                sessionState is PortalSessionState.Checking ||
                sessionState is PortalSessionState.Ready ||
                sessionState is PortalSessionState.Unavailable
            ) {
                WebMaterialReader(
                    url = url,
                    adapterScript = adapterScript,
                    schoolConfigJson = schoolConfigJson,
                refreshToken = refreshToken,
                action = readerAction,
                modifier = Modifier.fillMaxSize().alpha(0.01f),
                onLoading = { loading = it },
                onContent = {
                    page = it
                    loading = false
                    error = null
                    PortalSessionCoordinator.markAuthenticated()
                },
                onError = { error = it },
                onSessionExpired = onSessionExpired
            )
            }

            val contentStage = when {
                // A cached snapshot is useful even while session validation or refresh is running.
                page != null -> MaterialContentStage.CONTENT
                sessionState is PortalSessionState.Checking -> MaterialContentStage.AUTHENTICATING
                sessionState is PortalSessionState.Unavailable -> MaterialContentStage.AUTH_UNAVAILABLE
                sessionState is PortalSessionState.Expired || sessionState is PortalSessionState.NoSession ->
                    MaterialContentStage.SESSION_EXPIRED
                error != null -> MaterialContentStage.ERROR
                else -> MaterialContentStage.FETCHING
            }
            AnimatedContent(
                targetState = contentStage,
                modifier = Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background),
                transitionSpec = {
                    if (targetState == MaterialContentStage.CONTENT) {
                        (
                            fadeIn(
                                animationSpec = tween(
                                    durationMillis = 220,
                                    delayMillis = 35,
                                    easing = FastOutSlowInEasing
                                )
                            ) +
                                slideInVertically(
                                    animationSpec = tween(
                                        durationMillis = 280,
                                        easing = FastOutSlowInEasing
                                    ),
                                    initialOffsetY = { it / 32 }
                                ) +
                                scaleIn(
                                    animationSpec = tween(
                                        durationMillis = 260,
                                        easing = FastOutSlowInEasing
                                    ),
                                    initialScale = 0.992f
                                )
                            ) togetherWith (
                            fadeOut(animationSpec = tween(110)) +
                                scaleOut(animationSpec = tween(140), targetScale = 0.985f)
                            )
                    } else {
                        (
                            fadeIn(animationSpec = tween(180, easing = FastOutSlowInEasing)) +
                                slideInVertically(
                                    animationSpec = tween(240, easing = FastOutSlowInEasing),
                                    initialOffsetY = { it / 18 }
                                )
                            ) togetherWith (
                            fadeOut(animationSpec = tween(120)) +
                                slideOutVertically(
                                    animationSpec = tween(150, easing = FastOutSlowInEasing),
                                    targetOffsetY = { -it / 24 }
                                )
                            )
                    }
                },
                label = "secondary-page-content"
            ) { stage ->
                Box(Modifier.fillMaxSize()) {
                    when (stage) {
                        MaterialContentStage.AUTHENTICATING -> LoadingPane("尝试登录…", Modifier.align(Alignment.Center))
                        MaterialContentStage.AUTH_UNAVAILABLE -> Column(
                            modifier = Modifier.align(Alignment.Center).padding(24.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(12.dp)
                        ) {
                            ErrorCard(
                                (sessionState as? PortalSessionState.Unavailable)?.message
                                    ?: "暂时无法验证登录状态"
                            )
                            Button(onClick = {
                                PortalSessionCoordinator.validate(
                                    context.applicationContext as android.app.Application,
                                    force = true
                                )
                            }) { Text("重试") }
                        }
                        MaterialContentStage.FETCHING -> LoadingPane("获取数据…", Modifier.align(Alignment.Center))
                        MaterialContentStage.CONTENT -> page?.let {
                            MaterialPageList(it, onOpenLink, performAction, loading)
                        }
                        MaterialContentStage.ERROR -> ErrorCard(error.orEmpty(), Modifier.align(Alignment.Center))
                        MaterialContentStage.SESSION_EXPIRED -> LoadingPane("登录状态已失效", Modifier.align(Alignment.Center))
                    }
                }
            }
        }
    }
}

@Composable
private fun MaterialPageList(
    page: MaterialPage,
    onOpenLink: (String, String) -> Unit,
    onAction: (String, String) -> Unit,
    loading: Boolean
) {
    val schedule = page.sections.filterIsInstance<MaterialSection.Schedule>().firstOrNull()
    var selectedScheduleDay by remember(page.sourceUrl, schedule?.title) {
        mutableStateOf<String?>(null)
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize().animateContentSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        if (page.choices.isNotEmpty() || page.actions.isNotEmpty() || schedule != null) {
            item(key = "page-controls") {
                Box(
                    Modifier.animateItem(
                        fadeInSpec = tween(220, easing = FastOutSlowInEasing),
                        placementSpec = tween(300, easing = FastOutSlowInEasing),
                        fadeOutSpec = tween(120)
                    )
                ) {
                    PageControls(
                        page = page,
                        scheduleDays = schedule?.days.orEmpty(),
                        selectedScheduleDay = selectedScheduleDay,
                        onScheduleDaySelected = { selectedScheduleDay = it },
                        onAction = onAction
                    )
                }
            }
        }
        if (loading && page.sections.isNotEmpty()) {
            item(key = "page-refreshing") {
                LinearProgressIndicator(
                    modifier = Modifier.fillMaxWidth().animateItem(
                        fadeInSpec = tween(160, easing = FastOutSlowInEasing),
                        placementSpec = tween(220, easing = FastOutSlowInEasing),
                        fadeOutSpec = tween(100)
                    )
                )
            }
        } else if (loading) {
            item(key = "page-loading") {
                Box(
                    Modifier.fillMaxWidth().padding(vertical = 48.dp).animateItem(
                        fadeInSpec = tween(160, easing = FastOutSlowInEasing),
                        placementSpec = tween(280, easing = FastOutSlowInEasing),
                        fadeOutSpec = tween(100)
                    ),
                    contentAlignment = Alignment.Center
                ) { LoadingPane("获取数据…") }
            }
        } else if (page.sections.isEmpty()) {
            item { ErrorCard("页面已加载，但当前适配器没有识别出可展示的内容。") }
        }
        page.sections.forEach { section ->
                item(key = section.hashCode()) {
                    Box(
                        Modifier.animateItem(
                            fadeInSpec = tween(240, easing = FastOutSlowInEasing),
                            placementSpec = tween(320, easing = FastOutSlowInEasing),
                            fadeOutSpec = tween(120)
                        )
                    ) {
                        when (section) {
                            is MaterialSection.Table -> MaterialTable(section)
                            is MaterialSection.Fields -> FieldCard(section)
                            is MaterialSection.Text -> TextCard(section)
                            is MaterialSection.Links -> LinkCard(section, onOpenLink)
                            is MaterialSection.Schedule -> ScheduleSection(section, selectedScheduleDay)
                            is MaterialSection.Cards -> CardsSection(section)
                            is MaterialSection.Program -> ProgramSection(section)
                            is MaterialSection.Stats -> StatsSection(section)
                        }
                    }
                }
            }
    }
}

@Composable
private fun LoadingPane(message: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        CircularProgressIndicator()
        Text(
            text = message,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.Medium
        )
    }
}

@Composable
private fun PageControls(
    page: MaterialPage,
    scheduleDays: List<ScheduleDay>,
    selectedScheduleDay: String?,
    onScheduleDaySelected: (String?) -> Unit,
    onAction: (String, String) -> Unit
) {
    Card(
        shape = RoundedCornerShape(18.dp),
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = PortalControlBackground)
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            page.choices.forEach { choice ->
                Text(choice.label, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                ChoiceMenu(choice, onAction)
            }
            if (scheduleDays.isNotEmpty()) {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    item(key = "all-schedule-days") {
                        val selected = selectedScheduleDay == null
                        FilterChip(
                            selected = selected,
                            onClick = { onScheduleDaySelected(null) },
                            label = { Text("全部显示") },
                            border = BorderStroke(
                                1.dp,
                                if (selected) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.42f)
                            )
                        )
                    }
                    items(scheduleDays, key = { it.name }) { day ->
                        val selected = selectedScheduleDay == day.name
                        FilterChip(
                            selected = selected,
                            onClick = { onScheduleDaySelected(day.name) },
                            label = { Text(day.name.replace("星期", "周")) },
                            border = BorderStroke(
                                1.dp,
                                if (selected) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.42f)
                            )
                        )
                    }
                }
            }
            if (page.actions.isNotEmpty()) {
                Text("排名类型", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(page.actions, key = { "${it.id}:${it.value}" }) { action ->
                        OutlinedButton(onClick = { onAction(action.id, action.value) }) {
                            Text(action.label)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ExportMenu(
    showHint: Boolean,
    onHintDismissed: () -> Unit,
    onExport: (String) -> Unit
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = {
            if (showHint) onHintDismissed()
            expanded = true
        }) {
            Icon(Icons.Outlined.FileDownload, "导出课表")
        }
        DropdownMenu(
            expanded = expanded || showHint,
            onDismissRequest = {
                expanded = false
                if (showHint) onHintDismissed()
            },
            shape = RoundedCornerShape(16.dp),
            containerColor = PortalCardBackground,
            tonalElevation = 0.dp,
            shadowElevation = 8.dp
        ) {
            if (showHint && !expanded) {
                DropdownMenuItem(
                    text = {
                        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text("课表支持导出", fontWeight = FontWeight.SemiBold)
                            Text(
                                "点击右上角按钮，可导出日历或 WakeUp 课程表格式。",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    },
                    onClick = onHintDismissed
                )
            } else {
                listOf(
                    "ics" to "iCalendar 日历",
                    "csv" to "WakeUp 课程表 CSV",
                    "json" to "JSON 数据"
                ).forEach { (format, label) ->
                    DropdownMenuItem(
                        text = { Text(label) },
                        onClick = { expanded = false; onExport(format) }
                    )
                }
            }
        }
    }
}

@Composable
private fun ChoiceMenu(choice: MaterialChoice, onAction: (String, String) -> Unit) {
    var expanded by remember(choice.id) { mutableStateOf(false) }
    val selectedLabel = choice.options.firstOrNull { it.value == choice.value }?.label
        ?: choice.options.firstOrNull()?.label.orEmpty()
    Box(Modifier.fillMaxWidth()) {
        OutlinedButton(
            onClick = { expanded = true },
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(14.dp),
            colors = ButtonDefaults.outlinedButtonColors(containerColor = PortalPageBackground)
        ) {
            Box(modifier = Modifier.fillMaxWidth()) {
                AnimatedContent(
                    targetState = selectedLabel.ifBlank { "请选择" },
                    modifier = Modifier.align(Alignment.Center),
                    transitionSpec = { fadeIn() togetherWith fadeOut() },
                    label = "secondary-menu-selection"
                ) { label ->
                    Text(text = label, textAlign = TextAlign.Center)
                }
                Icon(
                    Icons.Outlined.KeyboardArrowDown,
                    "展开学期菜单",
                    modifier = Modifier.align(Alignment.CenterEnd)
                )
            }
        }
        Box(Modifier.align(Alignment.BottomEnd)) {
            DropdownMenu(
                expanded = expanded,
                onDismissRequest = { expanded = false },
                modifier = Modifier.widthIn(min = 236.dp, max = 320.dp),
                offset = DpOffset(0.dp, 4.dp),
                shape = RoundedCornerShape(16.dp),
                containerColor = MaterialTheme.colorScheme.background,
                tonalElevation = 0.dp,
                shadowElevation = 12.dp
            ) {
                choice.options.forEach { option ->
                    DropdownMenuItem(
                        text = {
                            Text(
                                text = option.label,
                                modifier = Modifier.fillMaxWidth(),
                                textAlign = TextAlign.Center,
                                fontWeight = if (option.value == choice.value) {
                                    FontWeight.SemiBold
                                } else FontWeight.Normal
                            )
                        },
                        onClick = {
                            expanded = false
                            if (option.value != choice.value) onAction(choice.id, option.value)
                        }
                    )
                }
            }
        }
    }
}

@Composable
private fun StatsSection(section: MaterialSection.Stats) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (section.title.isNotBlank()) {
            Text(section.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        }
        Row(
            Modifier.fillMaxWidth().height(84.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            section.items.forEach { item ->
                Column(
                    Modifier.weight(1f).fillMaxHeight()
                        .background(PortalBlueSoft, RoundedCornerShape(14.dp)).padding(10.dp),
                    verticalArrangement = Arrangement.spacedBy(3.dp)
                ) {
                    Text(item.label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(item.value.ifBlank { "—" }, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

@Composable
private fun ProgramSection(section: MaterialSection.Program) {
    val completed = section.completedCredits.toFloatOrNull() ?: 0f
    val required = section.requiredCredits.toFloatOrNull() ?: 0f
    val progress = if (required > 0f) (completed / required).coerceIn(0f, 1f) else 0f
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Card(
            shape = RoundedCornerShape(18.dp),
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(containerColor = PortalCardBackground)
        ) {
            Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("完成学分", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Text(
                    "${section.completedCredits.ifBlank { "—" }} / ${section.requiredCredits.ifBlank { "—" }}",
                    style = MaterialTheme.typography.headlineMedium,
                    color = PortalBlue,
                    fontWeight = FontWeight.Bold
                )
                Text("已完成 / 培养方案要求", color = MaterialTheme.colorScheme.onSurfaceVariant)
                LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth())
            }
        }
        if (section.title.isNotBlank()) {
            Text(section.title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        }
        section.modules.forEach { module -> ProgramModuleCard(module) }
    }
}

@Composable
private fun ProgramModuleCard(module: ProgramModule) {
    var expanded by remember(module.id) { mutableStateOf(module.depth == 1) }
    Card(
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = PortalCardBackground)
    ) {
        Column {
            Row(
                Modifier.fillMaxWidth().clickable { expanded = !expanded }.padding(14.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Text(module.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    module.requirements.forEach { requirement ->
                        Text(requirement, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (module.status.isNotBlank()) {
                        Text(
                            when (module.status) {
                                "PASSED" -> "已完成"
                                "FAILED" -> "未完成"
                                else -> module.status
                            },
                            style = MaterialTheme.typography.labelMedium,
                            color = if (module.status == "PASSED") PortalSuccess else MaterialTheme.colorScheme.error
                        )
                    }
                }
                Icon(if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, if (expanded) "折叠" else "展开")
            }
            if (expanded) {
                if (module.courses.isNotEmpty()) {
                    HorizontalDivider()
                    Column(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 6.dp)) {
                        if (module.headers.isNotEmpty()) TableRow(module.headers, header = true)
                        module.courses.forEachIndexed { index, row ->
                            TableRow(row, header = false, alternate = index % 2 == 1)
                        }
                    }
                }
                if (module.children.isNotEmpty()) {
                    Column(
                        Modifier.fillMaxWidth().padding(start = 12.dp, end = 8.dp, bottom = 10.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        module.children.forEach { child -> ProgramModuleCard(child) }
                    }
                }
            }
        }
    }
}

@Composable
private fun ScheduleSection(section: MaterialSection.Schedule, selectedDay: String?) {
    Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
        if (section.title.isNotBlank()) {
            Text(section.title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        }
        AnimatedContent(
            targetState = selectedDay,
            transitionSpec = {
                (
                    fadeIn(animationSpec = tween(220, easing = FastOutSlowInEasing)) +
                        slideInHorizontally(
                            animationSpec = tween(280, easing = FastOutSlowInEasing),
                            initialOffsetX = { it / 12 }
                        )
                    ) togetherWith (
                    fadeOut(animationSpec = tween(120)) +
                        slideOutHorizontally(
                            animationSpec = tween(160, easing = FastOutSlowInEasing),
                            targetOffsetX = { -it / 18 }
                        )
                    )
            },
            label = "schedule-day-filter"
        ) { dayName ->
            val visibleDays = if (dayName == null) section.days else section.days.filter { it.name == dayName }
            Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
                visibleDays.forEach { day ->
                    if (day.lessons.isNotEmpty()) {
                        Text(day.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                        day.lessons.forEach { MaterialInfoCard(it, compact = true) }
                    }
                }
                if (visibleDays.all { it.lessons.isEmpty() }) {
                    TextCard(
                        MaterialSection.Text(
                            "提示",
                            listOf(if (dayName == null) "当前课表暂无课程" else "${dayName.replace("星期", "周")}暂无课程")
                        )
                    )
                }
            }
        }
    }
}

@Composable
private fun CardsSection(section: MaterialSection.Cards) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (section.title.isNotBlank()) {
            Text(section.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        }
        if (section.cards.isEmpty()) {
            TextCard(MaterialSection.Text("", listOf("暂无数据")))
        } else {
            section.cards.forEach { MaterialInfoCard(it, compact = true) }
        }
    }
}

@Composable
private fun MaterialInfoCard(item: MaterialCardItem, compact: Boolean = false) {
    Card(
        shape = RoundedCornerShape(18.dp),
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = PortalCardBackground)
    ) {
        Column(
            Modifier.padding(if (compact) 12.dp else 16.dp),
            verticalArrangement = Arrangement.spacedBy(if (compact) 5.dp else 9.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(item.title.ifBlank { "未命名项目" }, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    if (item.subtitle.isNotBlank()) {
                        Text(item.subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                if (item.accent.isNotBlank()) {
                    Text(
                        item.accent,
                        style = MaterialTheme.typography.labelLarge,
                        color = PortalBlue,
                        modifier = Modifier.background(PortalBlueSoft, RoundedCornerShape(8.dp)).padding(horizontal = 8.dp, vertical = 4.dp)
                    )
                }
            }
            if (compact) {
                item.fields.filter { it.second.isNotBlank() }.chunked(2).forEach { fields ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        fields.forEach { (label, value) ->
                            Column(Modifier.weight(1f)) {
                                Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                Text(value, style = MaterialTheme.typography.bodySmall)
                            }
                        }
                        if (fields.size == 1) Spacer(Modifier.weight(1f))
                    }
                }
            } else {
                item.fields.forEach { (label, value) ->
                    if (value.isNotBlank()) {
                        Column {
                            Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(value, style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MaterialTable(section: MaterialSection.Table) {
    Card(
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = PortalCardBackground)
    ) {
        Column(Modifier.padding(vertical = 14.dp)) {
            if (section.title.isNotBlank()) Text(section.title, fontWeight = FontWeight.Bold, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
            val scroll = rememberScrollState()
            Column(Modifier.horizontalScroll(scroll)) {
                TableRow(section.headers, header = true)
                HorizontalDivider()
                section.rows.forEachIndexed { index, row ->
                    TableRow(row, header = false, alternate = index % 2 == 1)
                }
            }
        }
    }
}

@Composable
private fun TableRow(values: List<String>, header: Boolean, alternate: Boolean = false) {
    Row(Modifier.background(if (alternate) MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f) else Color.Transparent)) {
        values.forEach { value ->
            Text(
                value.ifBlank { "—" },
                modifier = Modifier.width(148.dp).padding(horizontal = 12.dp, vertical = 10.dp),
                style = if (header) MaterialTheme.typography.labelLarge else MaterialTheme.typography.bodyMedium,
                fontWeight = if (header) FontWeight.Bold else FontWeight.Normal
            )
        }
    }
}

@Composable
private fun FieldCard(section: MaterialSection.Fields) {
    Card(
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = PortalCardBackground)
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (section.title.isNotBlank()) Text(section.title, fontWeight = FontWeight.Bold)
            section.fields.forEach { (label, value) ->
                Column {
                    Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(value, style = MaterialTheme.typography.bodyLarge)
                }
            }
        }
    }
}

@Composable
private fun TextCard(section: MaterialSection.Text) {
    Card(
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = PortalCardBackground)
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (section.title.isNotBlank()) Text(section.title, fontWeight = FontWeight.Bold)
            section.paragraphs.forEach { Text(it, style = MaterialTheme.typography.bodyMedium) }
        }
    }
}

@Composable
private fun LinkCard(section: MaterialSection.Links, onOpenLink: (String, String) -> Unit) {
    Card(
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = PortalCardBackground)
    ) {
        Column {
            if (section.title.isNotBlank()) Text(section.title, fontWeight = FontWeight.Bold, modifier = Modifier.padding(16.dp))
            section.links.forEachIndexed { index, (title, url) ->
                Row(
                    Modifier.fillMaxWidth().clickable { onOpenLink(title, url) }.padding(horizontal = 16.dp, vertical = 13.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(title, Modifier.weight(1f))
                    Spacer(Modifier.size(8.dp))
                    Icon(Icons.Outlined.ChevronRight, null)
                }
                if (index != section.links.lastIndex) HorizontalDivider(Modifier.padding(horizontal = 16.dp))
            }
        }
    }
}

@Composable
private fun ErrorCard(message: String, modifier: Modifier = Modifier) {
    Card(
        modifier = modifier.padding(24.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer)
    ) { Text(message, Modifier.padding(18.dp)) }
}

private data class WakeUpCourseDetails(
    val startSection: String,
    val endSection: String,
    val teacher: String,
    val location: String,
    val weeks: String,
    val startTime: String = "",
    val endTime: String = ""
)

private val fallbackUnitTimes = mapOf(
    "1" to ("09:30" to "10:15"),
    "2" to ("10:20" to "11:05"),
    "3" to ("11:25" to "12:10"),
    "4" to ("12:15" to "13:00"),
    "5" to ("13:05" to "13:50"),
    "6" to ("16:00" to "16:45"),
    "7" to ("16:50" to "17:35"),
    "8" to ("17:55" to "18:40"),
    "9" to ("18:45" to "19:30"),
    "10" to ("20:30" to "21:15"),
    "11" to ("21:20" to "22:05"),
    "12" to ("22:10" to "22:55")
)

internal fun scheduleToCsv(schedule: MaterialSection.Schedule): String = buildString {
    // WakeUp 课程表 CSV 导入格式，表头顺序与官方模板保持一致。
    appendLine("课程名称,星期,开始节数,结束节数,老师,地点,周数")
    schedule.days.forEachIndexed { dayIndex, day ->
        day.lessons.forEach { lesson ->
            val details = courseScheduleDetails(lesson)
            appendLine(
                listOf(
                    lesson.title,
                    (dayIndex + 1).toString(),
                    details.startSection,
                    details.endSection,
                    details.teacher,
                    details.location,
                    details.weeks
                )
                    .joinToString(",") { csvValue(it) }
            )
        }
    }
}

private fun courseScheduleDetails(lesson: MaterialCardItem): WakeUpCourseDetails {
    lesson.schedule?.let { schedule ->
        return WakeUpCourseDetails(
            startSection = schedule.startSection,
            endSection = schedule.endSection,
            teacher = schedule.teacher,
            location = schedule.location,
            weeks = schedule.weeks,
            startTime = schedule.startTime,
            endTime = schedule.endTime
        )
    }
    val fields = lesson.fields.toMap()
    val parsed = parseWakeUpCourseDetails(fields["时间与地点"].orEmpty())
    val sectionRange = Regex("(\\d+)\\s*[-~～—至]\\s*(\\d+)\\s*节?")
        .find(fields["节次"].orEmpty())
    val startSection = fields["开始节数"].orEmpty().ifBlank {
        sectionRange?.groupValues?.getOrNull(1).orEmpty().ifBlank { parsed.startSection }
    }
    val endSection = fields["结束节数"].orEmpty().ifBlank {
        sectionRange?.groupValues?.getOrNull(2).orEmpty().ifBlank { parsed.endSection }
    }
    return parsed.copy(
        startSection = startSection,
        endSection = endSection,
        teacher = fields["老师"].orEmpty().ifBlank { fields["教师"].orEmpty() }.ifBlank { parsed.teacher },
        location = fields["地点"].orEmpty().ifBlank { fields["教室"].orEmpty() }.ifBlank { parsed.location },
        weeks = fields["周数"].orEmpty().ifBlank { parsed.weeks },
        startTime = fields["开始时间"].orEmpty(),
        endTime = fields["结束时间"].orEmpty()
    )
}

private fun parseWakeUpCourseDetails(rawValue: String): WakeUpCourseDetails {
    val pieces = rawValue.split(Regex("\\s*[·|]\\s*|[\\r\\n]+"))
        .map(String::trim)
        .filter(String::isNotBlank)
    val sectionRange = Regex("(?:第\\s*)?(\\d+)\\s*[-~～—至]\\s*(\\d+)\\s*节")
        .find(rawValue)
    val singleSection = Regex("(?:第\\s*)?(\\d+)\\s*节").find(rawValue)
    val startSection = sectionRange?.groupValues?.getOrNull(1)
        ?: singleSection?.groupValues?.getOrNull(1).orEmpty()
    val endSection = sectionRange?.groupValues?.getOrNull(2)
        ?: singleSection?.groupValues?.getOrNull(1).orEmpty()

    val weekTokens = Regex(
        "(\\d+)(?:\\s*[-~～—至]\\s*(\\d+))?\\s*(?:(单|双)\\s*)?周\\s*(?:[（(]?\\s*(单|双)\\s*[）)]?)?"
    ).findAll(rawValue).map { match ->
        val start = match.groupValues[1]
        val end = match.groupValues[2]
        val parity = match.groupValues[3].ifBlank { match.groupValues[4] }
        buildString {
            append(start)
            if (end.isNotBlank() && end != start) append("-").append(end)
            append(parity)
        }
    }.distinct().toList()

    val labeledTeacher = Regex("(?:教师|老师)\\s*[:：]\\s*([^·|,，;；]+)")
        .find(rawValue)?.groupValues?.getOrNull(1)?.trim().orEmpty()
    val labeledLocation = Regex("(?:地点|教室|上课地点)\\s*[:：]\\s*([^·|,，;；]+)")
        .find(rawValue)?.groupValues?.getOrNull(1)?.trim().orEmpty()
    val locationPattern = Regex("楼|教室|室|馆|场|中心|校区|[A-Za-z]\\d{1,2}[-－]\\d{2,4}")
    val teacherMatches = Regex("([\\u3400-\\u9fffA-Za-z·.'-]{1,40})\\s*\\(\\s*\\d{4,}\\s*\\)")
        .findAll(rawValue).toList()
    val scheduleTail = Regex("\\d+\\s*节\\s*[）)]?\\s*(.*)$")
        .find(rawValue)?.groupValues?.getOrNull(1).orEmpty()
    val firstTeacherOffset = teacherMatches.firstOrNull()?.range?.first
    val tailOffset = rawValue.indexOf(scheduleTail).takeIf { it >= 0 }
    val inferredLocation = if (firstTeacherOffset != null && tailOffset != null && firstTeacherOffset >= tailOffset) {
        rawValue.substring(tailOffset, firstTeacherOffset).trim()
    } else ""
    val location = labeledLocation.ifBlank {
        inferredLocation.ifBlank { pieces.firstOrNull { locationPattern.containsMatchIn(it) }.orEmpty() }
    }
    val teacher = labeledTeacher.ifBlank {
        teacherMatches.joinToString("/") { it.groupValues[1] }.ifBlank { pieces.firstOrNull { piece ->
            !piece.contains("星期") &&
                !piece.contains("周") &&
                !piece.contains("节") &&
                !piece.contains("教学班") &&
                !locationPattern.containsMatchIn(piece) &&
                !piece.contains(Regex("\\d{3,}"))
        }.orEmpty() }
    }
    return WakeUpCourseDetails(
        startSection = startSection,
        endSection = endSection,
        teacher = teacher,
        location = location,
        weeks = weekTokens.joinToString("、")
    )
}

private fun scheduleToJson(schedule: MaterialSection.Schedule): String {
    val days = JSONArray()
    schedule.days.forEach { day ->
        val lessons = JSONArray()
        day.lessons.forEach { lesson ->
            val fields = JSONObject()
            lesson.fields.forEach { (label, value) -> fields.put(label, value) }
            lessons.put(
                JSONObject()
                    .put("name", lesson.title)
                    .put("code", lesson.subtitle)
                    .put("fields", fields)
            )
        }
        days.put(JSONObject().put("day", day.name).put("lessons", lessons))
    }
    return JSONObject()
        .put("semester", schedule.title)
        .put("semesterStartDate", schedule.semesterStartDate)
        .put("days", days)
        .toString(2)
}

internal fun scheduleToIcs(
    schedule: MaterialSection.Schedule,
    unitTimes: Map<String, Pair<String, String>> = fallbackUnitTimes
): String {
    val semesterStart = runCatching { LocalDate.parse(schedule.semesterStartDate) }.getOrElse { LocalDate.now() }
    val dateTimeFormat = DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss")
    val stamp = java.time.ZonedDateTime.now(ZoneOffset.UTC)
        .format(DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'"))
    return buildString {
        append("BEGIN:VCALENDAR\r\n")
        append("VERSION:2.0\r\n")
        append("PRODID:-//PalmAcademic//Schedule//ZH-CN\r\n")
        append("CALSCALE:GREGORIAN\r\n")
        append("METHOD:PUBLISH\r\n")
        append("X-WR-CALNAME:${icsValue(schedule.title.ifBlank { "掌上教务课表" })}\r\n")
        append("X-WR-TIMEZONE:Asia/Shanghai\r\n")
        append("BEGIN:VTIMEZONE\r\nTZID:Asia/Shanghai\r\n")
        append("BEGIN:STANDARD\r\nDTSTART:19700101T000000\r\n")
        append("TZOFFSETFROM:+0800\r\nTZOFFSETTO:+0800\r\nTZNAME:CST\r\n")
        append("END:STANDARD\r\nEND:VTIMEZONE\r\n")
        schedule.days.forEachIndexed { dayIndex, day ->
            day.lessons.forEach { lesson ->
                val fields = lesson.fields.toMap()
                val details = courseScheduleDetails(lesson)
                val startTime = parseCourseTime(details.startTime)
                    ?: unitTimes[details.startSection]?.first?.let(::parseCourseTime)
                    ?: return@forEach
                val endTime = parseCourseTime(details.endTime)
                    ?: unitTimes[details.endSection]?.second?.let(::parseCourseTime)
                    ?: return@forEach
                val occurrenceWeeks = expandCourseWeeks(details.weeks).ifEmpty { listOf(1) }
                occurrenceWeeks.forEach { week ->
                    val date = semesterStart.plusWeeks((week - 1).toLong()).plusDays(dayIndex.toLong())
                    val startsAt = date.atTime(startTime)
                    val endsAt = date.atTime(endTime)
                    val uidSource = listOf(
                        schedule.title, day.name, lesson.title, lesson.subtitle,
                        details.weeks, details.startSection, details.endSection,
                        details.teacher, details.location, week.toString()
                    ).joinToString("|")
                    val description = listOf(
                        lesson.subtitle,
                        "第${details.startSection}-${details.endSection}节",
                        "第${details.weeks}周",
                        details.teacher.takeIf(String::isNotBlank)?.let { "老师：$it" }.orEmpty(),
                        fields["教学班"].orEmpty()
                    ).filter(String::isNotBlank).joinToString(" | ")
                    append("BEGIN:VEVENT\r\n")
                    append("UID:${uidSource.hashCode()}-$week@palmacademic\r\n")
                    append("DTSTAMP:$stamp\r\n")
                    append("DTSTART;TZID=Asia/Shanghai:${startsAt.format(dateTimeFormat)}\r\n")
                    append("DTEND;TZID=Asia/Shanghai:${endsAt.format(dateTimeFormat)}\r\n")
                    append("SUMMARY:${icsValue(lesson.title)}\r\n")
                    if (details.location.isNotBlank()) append("LOCATION:${icsValue(details.location)}\r\n")
                    append("DESCRIPTION:${icsValue(description)}\r\n")
                    append("END:VEVENT\r\n")
                }
            }
        }
        append("END:VCALENDAR\r\n")
    }
}

private fun parseCourseTime(value: String): LocalTime? =
    runCatching { LocalTime.parse(value, DateTimeFormatter.ofPattern("H:mm")) }.getOrNull()

private fun expandCourseWeeks(value: String): List<Int> {
    val normalized = value
        .replace("（", "")
        .replace("）", "")
        .replace("(", "")
        .replace(")", "")
        .replace("周", "")
        .replace(Regex("[~～—至]"), "-")
        .replace(Regex("[,，;；]"), "、")
    return normalized.split("、")
        .flatMap { token ->
            val match = Regex("(\\d+)\\s*(?:-\\s*(\\d+))?\\s*(单|双)?").matchEntire(token.trim())
                ?: return@flatMap emptyList()
            val start = match.groupValues[1].toIntOrNull() ?: return@flatMap emptyList()
            val end = match.groupValues[2].toIntOrNull() ?: start
            val parity = match.groupValues[3]
            (minOf(start, end)..maxOf(start, end)).filter { week ->
                parity.isBlank() || (parity == "单" && week % 2 == 1) || (parity == "双" && week % 2 == 0)
            }
        }
        .filter { it > 0 }
        .distinct()
        .sorted()
}

private fun csvValue(value: String): String = "\"${value.replace("\"", "\"\"")}\""

private fun icsValue(value: String): String = value
    .replace("\\", "\\\\")
    .replace(";", "\\;")
    .replace(",", "\\,")
    .replace("\r", "")
    .replace("\n", "\\n")
