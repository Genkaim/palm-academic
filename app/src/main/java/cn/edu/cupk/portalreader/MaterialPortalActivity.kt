package cn.edu.cupk.portalreader

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
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
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.pulltorefresh.pullToRefresh
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private data class ExportDocument(val fileName: String, val content: String)
private data class MaterialReaderResources(
    val adapterScript: String,
    val schoolConfigJson: String,
    val fallbackUnitTimes: Map<String, Pair<String, String>>
)
private const val FEATURE_HINT_PREFERENCES = "feature_hints"
private const val KEY_SCHEDULE_EXPORT_HINT_SHOWN = "schedule_export_hint_shown_v1"

private enum class MaterialContentStage {
    AUTHENTICATING,
    AUTH_UNAVAILABLE,
    FETCHING,
    CONTENT,
    ERROR,
    SESSION_EXPIRED
}
private enum class MaterialGroupPosition { ONLY, FIRST, MIDDLE, LAST }

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
        val initialCachedPage = MaterialPageCache.load(this, requestedUrl)
        setContent {
            PortalTheme {
                var sessionExpired by remember { mutableStateOf(false) }
                var readerResources by remember { mutableStateOf<MaterialReaderResources?>(null) }
                var resourceError by remember { mutableStateOf<String?>(null) }
                LaunchedEffect(Unit) {
                    runCatching {
                        withContext(Dispatchers.IO) {
                            val school = SchoolAdapterRepository.load(this@MaterialPortalActivity)
                            MaterialReaderResources(
                                adapterScript = SchoolAdapterRepository.readAdapterScript(
                                    this@MaterialPortalActivity,
                                    school.adapterAsset
                                ),
                                schoolConfigJson = school.readerConfigJson,
                                fallbackUnitTimes = school.fallbackUnitTimes
                            )
                        }
                    }.onSuccess { resources ->
                        fallbackUnitTimes = resources.fallbackUnitTimes
                        readerResources = resources
                    }.onFailure { throwable ->
                        resourceError = throwable.message ?: "页面配置加载失败"
                    }
                }
                MaterialPortalContent(
                    requestedTitle = requestedTitle,
                    url = requestedUrl,
                    initialPage = initialCachedPage,
                    readerResources = readerResources,
                    resourceError = resourceError,
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
    initialPage: MaterialPage?,
    readerResources: MaterialReaderResources?,
    resourceError: String?,
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
    var page by remember(url) { mutableStateOf(initialPage) }
    var firstFrameReady by remember(url) { mutableStateOf(false) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    // Every activity entry is a real refresh. A cached page still renders immediately, while
    // this non-zero token marks the initial network load as the current refresh cycle.
    var refreshToken by remember(url) { mutableIntStateOf(1) }
    var actionToken by remember { mutableIntStateOf(0) }
    var readerAction by remember { mutableStateOf<MaterialReaderAction?>(null) }
    var showExportHint by remember { mutableStateOf(false) }
    var exportHintTriggered by remember { mutableStateOf(false) }
    val scheduleAvailable = page?.sections?.any { it is MaterialSection.Schedule } == true
    LaunchedEffect(url) {
        withFrameNanos { }
        firstFrameReady = true
    }
    LaunchedEffect(resourceError) {
        if (resourceError != null) {
            error = resourceError
            loading = false
        }
    }
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
    val refreshPage: () -> Unit = {
        error = null
        loading = true
        readerAction = null
        refreshToken++
    }
    val showForegroundLoading = loading && (
        initialPage == null || refreshToken > 0 || readerAction != null
        )

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            PortalGradientTopAppBar(
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
                    PortalTopBarRefreshButton(
                        refreshing = showForegroundLoading,
                        onClick = refreshPage
                    )
                }
            )
        }
    ) { padding ->
        Box(Modifier.fillMaxSize()) {
            if (
                firstFrameReady &&
                readerResources != null &&
                (
                    sessionState is PortalSessionState.Checking ||
                        sessionState is PortalSessionState.Ready ||
                        sessionState is PortalSessionState.Unavailable
                    )
            ) {
                WebMaterialReader(
                    url = url,
                    adapterScript = readerResources.adapterScript,
                    schoolConfigJson = readerResources.schoolConfigJson,
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
                            MaterialPageList(
                                page = it,
                                onOpenLink = onOpenLink,
                                onAction = performAction,
                                loading = showForegroundLoading,
                                animateItems = initialPage == null,
                                onRefresh = refreshPage,
                                topBarInset = padding.calculateTopPadding(),
                                bottomInset = padding.calculateBottomPadding()
                            )
                        }
                        MaterialContentStage.ERROR -> ErrorCard(error.orEmpty(), Modifier.align(Alignment.Center))
                        MaterialContentStage.SESSION_EXPIRED -> LoadingPane("登录状态已失效", Modifier.align(Alignment.Center))
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MaterialPageList(
    page: MaterialPage,
    onOpenLink: (String, String) -> Unit,
    onAction: (String, String) -> Unit,
    loading: Boolean,
    animateItems: Boolean,
    onRefresh: () -> Unit,
    topBarInset: Dp,
    bottomInset: Dp
) {
    val schedule = page.sections.filterIsInstance<MaterialSection.Schedule>().firstOrNull()
    var selectedScheduleDay by remember(page.sourceUrl, schedule?.title) {
        mutableStateOf<String?>(null)
    }
    val pullToRefreshState = rememberPullToRefreshState()
    val density = LocalDensity.current
    val pullOffsetPx = with(density) { 64.dp.toPx() }
    val windowWidth = with(density) { LocalWindowInfo.current.containerSize.width.toDp() }
    val horizontalContentPadding = if (windowWidth >= 600.dp) {
        32.dp
    } else {
        16.dp
    }
    val hapticFeedback = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    val returnOffset = remember { Animatable(0f) }
    val pullFraction = pullToRefreshState.distanceFraction.coerceIn(0f, 1f)
    var thresholdHapticPlayed by remember { mutableStateOf(false) }
    var returningFromPull by remember { mutableStateOf(false) }
    var suppressPullOffsetUntilReset by remember { mutableStateOf(false) }
    var userPullRefreshActive by remember { mutableStateOf(false) }
    val currentPullFraction by rememberUpdatedState(pullFraction)
    val currentLoading by rememberUpdatedState(loading)
    val currentReturningFromPull by rememberUpdatedState(returningFromPull)
    val pullReleaseConnection = remember {
        object : NestedScrollConnection {
            override suspend fun onPreFling(available: Velocity): Velocity {
                if (
                    !currentLoading && !currentReturningFromPull &&
                    currentPullFraction in 0.001f..<1f
                ) {
                    // Preserve the return-to-rest motion, but own it from this point onward.
                    // Material may continue settling internally; hiding that second motion
                    // removes only the rebound after the content reaches its resting place.
                    returnOffset.stop()
                    returnOffset.snapTo(currentPullFraction * pullOffsetPx)
                    returningFromPull = true
                    suppressPullOffsetUntilReset = true
                    scope.launch {
                        try {
                            returnOffset.animateTo(
                                targetValue = 0f,
                                animationSpec = tween(
                                    durationMillis = 180,
                                    easing = FastOutSlowInEasing
                                )
                            )
                        } finally {
                            returningFromPull = false
                        }
                    }
                }
                return Velocity.Zero
            }
        }
    }
    LaunchedEffect(pullFraction, loading, returningFromPull) {
        if (
            !loading && !returningFromPull && !suppressPullOffsetUntilReset &&
            pullFraction >= 1f && !thresholdHapticPlayed
        ) {
            hapticFeedback.performHapticFeedback(HapticFeedbackType.LongPress)
            thresholdHapticPlayed = true
        } else if (pullFraction < 1f) {
            thresholdHapticPlayed = false
        }
    }
    LaunchedEffect(loading, returningFromPull) {
        if (!loading && !returningFromPull && userPullRefreshActive) {
            // Refresh completion only removes the loading bar. The user-triggered return
            // animation has already happened at refresh start; an initial load never enters it.
            returnOffset.snapTo(0f)
            userPullRefreshActive = false
        }
    }
    LaunchedEffect(loading, returningFromPull, pullToRefreshState.distanceFraction) {
        if (
            !loading && !returningFromPull &&
            pullToRefreshState.distanceFraction <= 0.001f
        ) {
            suppressPullOffsetUntilReset = false
        }
    }
    Box(
        modifier = Modifier
            .fillMaxSize()
            .nestedScroll(pullReleaseConnection)
            .pullToRefresh(
                // Programmatic/initial refreshes must never drive Material's pull state.
                isRefreshing = loading && userPullRefreshActive,
                state = pullToRefreshState,
                enabled = !loading && !returningFromPull && !suppressPullOffsetUntilReset,
                threshold = 52.dp,
                onRefresh = {
                    if (!loading && !returningFromPull) {
                        val startOffset = pullToRefreshState.distanceFraction
                            .coerceIn(0f, 1.15f) * pullOffsetPx
                        scope.launch {
                            returnOffset.snapTo(startOffset)
                            returningFromPull = true
                            suppressPullOffsetUntilReset = true
                            userPullRefreshActive = true
                            onRefresh()
                            try {
                                returnOffset.animateTo(
                                    targetValue = 0f,
                                    animationSpec = tween(
                                        durationMillis = 180,
                                        easing = FastOutSlowInEasing
                                    )
                                )
                            } finally {
                                returningFromPull = false
                            }
                        }
                    }
                }
            )
    ) {
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer {
                    translationY = if (returningFromPull) {
                        returnOffset.value
                    } else if (!loading && !suppressPullOffsetUntilReset) {
                        pullToRefreshState.distanceFraction.coerceIn(0f, 1.15f) * pullOffsetPx
                    } else {
                        // Initial automatic refresh and toolbar refresh stay at rest.
                        0f
                    }
                },
            contentPadding = PaddingValues(
                start = horizontalContentPadding,
                top = (topBarInset - PortalTopFadeDepth).coerceAtLeast(0.dp) + 16.dp,
                end = horizontalContentPadding,
                bottom = bottomInset + 16.dp
            ),
            verticalArrangement = Arrangement.spacedBy(24.dp)
        ) {
            if (page.choices.isNotEmpty() || page.actions.isNotEmpty() || schedule != null) {
                item(key = "page-controls") {
                    Box(
                        Modifier.then(
                            if (animateItems) {
                                Modifier.animateItem(
                                    fadeInSpec = tween(180, easing = FastOutSlowInEasing),
                                    placementSpec = tween(240, easing = FastOutSlowInEasing),
                                    fadeOutSpec = tween(120)
                                )
                            } else Modifier
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
            if (loading && page.sections.isEmpty()) {
                item(key = "page-loading") {
                    Box(
                        Modifier.fillMaxWidth().padding(vertical = 48.dp).then(
                            if (animateItems) {
                                Modifier.animateItem(
                                    fadeInSpec = tween(160, easing = FastOutSlowInEasing),
                                    placementSpec = tween(220, easing = FastOutSlowInEasing),
                                    fadeOutSpec = tween(100)
                                )
                            } else Modifier
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
                        Modifier.then(
                            if (animateItems) {
                                Modifier.animateItem(
                                    fadeInSpec = tween(180, easing = FastOutSlowInEasing),
                                    placementSpec = tween(240, easing = FastOutSlowInEasing),
                                    fadeOutSpec = tween(120)
                                )
                            } else Modifier
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
        AnimatedVisibility(
            visible = loading,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = (topBarInset - PortalTopFadeDepth).coerceAtLeast(0.dp))
                .align(Alignment.TopCenter),
            enter = fadeIn(animationSpec = tween(100)),
            exit = fadeOut(animationSpec = tween(180))
        ) {
            LinearProgressIndicator(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp),
                color = MaterialTheme.colorScheme.onSurface,
                trackColor = MaterialTheme.colorScheme.surfaceVariant
            )
        }
        if (!loading && pullFraction > 0f && !suppressPullOffsetUntilReset) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = (topBarInset - PortalTopFadeDepth).coerceAtLeast(0.dp))
                    .height(36.dp)
                    .align(Alignment.TopCenter),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    "下拉刷新",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.labelMedium,
                    modifier = Modifier.alpha(pullFraction)
                )
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
        CircularProgressIndicator(color = MaterialTheme.colorScheme.onSurface)
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
    MaterialSectionBlock("筛选") {
        MaterialPanel(MaterialGroupPosition.ONLY) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                page.choices.forEach { choice ->
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(
                            choice.label,
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            fontWeight = FontWeight.Medium
                        )
                        ChoiceMenu(choice, onAction)
                    }
                }
                if (scheduleDays.isNotEmpty()) {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(
                            "显示日期",
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            fontWeight = FontWeight.Medium
                        )
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            item(key = "all-schedule-days") {
                                MaterialChoicePill(
                                    label = "全部",
                                    selected = selectedScheduleDay == null,
                                    onClick = { onScheduleDaySelected(null) }
                                )
                            }
                            items(scheduleDays, key = { it.name }) { day ->
                                MaterialChoicePill(
                                    label = day.name.replace("星期", "周"),
                                    selected = selectedScheduleDay == day.name,
                                    onClick = { onScheduleDaySelected(day.name) }
                                )
                            }
                        }
                    }
                }
                if (page.actions.isNotEmpty()) {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(
                            "排名类型",
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            fontWeight = FontWeight.Medium
                        )
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            items(page.actions, key = { "${it.id}:${it.value}" }) { action ->
                                OutlinedButton(
                                    onClick = { onAction(action.id, action.value) },
                                    modifier = Modifier.heightIn(min = 44.dp),
                                    shape = RoundedCornerShape(12.dp)
                                ) {
                                    Text(action.label)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MaterialChoicePill(
    label: String,
    selected: Boolean,
    onClick: () -> Unit
) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(12.dp))
            .background(
                if (selected) MaterialTheme.colorScheme.onSurface
                else MaterialTheme.colorScheme.surfaceVariant
            )
            .clickable(onClick = onClick)
            .heightIn(min = 44.dp)
            .padding(horizontal = 14.dp, vertical = 9.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            label,
            style = MaterialTheme.typography.labelMedium,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) MaterialTheme.colorScheme.surface
            else MaterialTheme.colorScheme.onSurfaceVariant
        )
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
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
            shape = RoundedCornerShape(14.dp),
            colors = ButtonDefaults.outlinedButtonColors(
                containerColor = MaterialTheme.colorScheme.surface,
                contentColor = MaterialTheme.colorScheme.onSurface
            ),
            border = BorderStroke(
                1.dp,
                MaterialTheme.colorScheme.outline.copy(alpha = 0.28f)
            )
        ) {
            Box(modifier = Modifier.fillMaxWidth()) {
                AnimatedContent(
                    targetState = selectedLabel.ifBlank { "请选择" },
                    modifier = Modifier.align(Alignment.Center),
                    transitionSpec = { fadeIn() togetherWith fadeOut() },
                    label = "secondary-menu-selection"
                ) { label ->
                    Text(
                        text = label,
                        textAlign = TextAlign.Center,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                }
                Icon(
                    Icons.Outlined.KeyboardArrowDown,
                    "展开学期菜单",
                    modifier = Modifier.align(Alignment.CenterEnd),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
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
                containerColor = MaterialTheme.colorScheme.surface,
                tonalElevation = 0.dp,
                shadowElevation = 12.dp
            ) {
                choice.options.forEach { option ->
                    val selected = option.value == choice.value
                    DropdownMenuItem(
                        modifier = Modifier
                            .padding(horizontal = 6.dp, vertical = 1.dp)
                            .clip(RoundedCornerShape(11.dp))
                            .background(
                                if (selected) MaterialTheme.colorScheme.surfaceVariant
                                else Color.Transparent
                            ),
                        text = {
                            Text(
                                text = option.label,
                                modifier = Modifier.fillMaxWidth(),
                                textAlign = TextAlign.Center,
                                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                                color = if (selected) MaterialTheme.colorScheme.onSurface
                                else MaterialTheme.colorScheme.onSurfaceVariant
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
    MaterialSectionBlock(section.title) {
        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(20.dp),
            colors = CardDefaults.cardColors(containerColor = PortalCardBackground),
            elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
        ) {
            Row(Modifier.fillMaxWidth().heightIn(min = 92.dp)) {
                section.items.forEachIndexed { index, item ->
                    if (index > 0) {
                        VerticalDivider(
                            modifier = Modifier.height(58.dp).align(Alignment.CenterVertically),
                            color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.55f)
                        )
                    }
                    Column(
                        Modifier.weight(1f).fillMaxHeight()
                            .padding(horizontal = 13.dp, vertical = 15.dp),
                        verticalArrangement = Arrangement.spacedBy(7.dp)
                    ) {
                        Text(
                            item.label,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Text(
                            item.value.ifBlank { "—" },
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
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
    Column(verticalArrangement = Arrangement.spacedBy(24.dp)) {
        MaterialSectionBlock("学分进度") {
            MaterialPanel(MaterialGroupPosition.ONLY) {
                Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.Bottom
                    ) {
                        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text(
                                "已完成学分",
                                style = MaterialTheme.typography.labelLarge,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Text(
                                section.completedCredits.ifBlank { "—" },
                                style = MaterialTheme.typography.headlineMedium,
                                color = MaterialTheme.colorScheme.onSurface,
                                fontWeight = FontWeight.Bold
                            )
                        }
                        Text(
                            "要求 ${section.requiredCredits.ifBlank { "—" }}",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(bottom = 4.dp)
                        )
                    }
                    LinearProgressIndicator(
                        progress = { progress },
                        modifier = Modifier.fillMaxWidth().height(7.dp)
                            .clip(RoundedCornerShape(4.dp)),
                        color = MaterialTheme.colorScheme.onSurface,
                        trackColor = MaterialTheme.colorScheme.surfaceVariant
                    )
                    Text(
                        if (required > 0f) "已完成 ${(progress * 100).toInt()}%" else "正在读取培养方案要求",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
        MaterialSectionBlock(section.title.ifBlank { "培养方案" }) {
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                section.modules.forEachIndexed { index, module ->
                    ProgramModuleCard(
                        module = module,
                        position = materialGroupPosition(index, section.modules.size)
                    )
                }
            }
        }
    }
}

@Composable
private fun ProgramModuleCard(
    module: ProgramModule,
    position: MaterialGroupPosition = MaterialGroupPosition.ONLY
) {
    var expanded by remember(module.id) { mutableStateOf(module.depth == 1) }
    MaterialPanel(
        position = position,
        containerColor = PortalCardBackground,
        border = if (module.depth > 1) {
            BorderStroke(
                0.5.dp,
                MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.48f)
            )
        } else null
    ) {
        Column {
            Row(
                Modifier.fillMaxWidth().clickable { expanded = !expanded }
                    .heightIn(min = 58.dp).padding(horizontal = 15.dp, vertical = 13.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Text(
                        module.title,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold
                    )
                    module.requirements.forEach { requirement ->
                        Text(
                            requirement,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    if (module.status.isNotBlank()) {
                        Text(
                            when (module.status) {
                                "PASSED" -> "已完成"
                                "FAILED" -> "未完成"
                                else -> module.status
                            },
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier
                                .background(
                                    MaterialTheme.colorScheme.surfaceVariant,
                                    RoundedCornerShape(8.dp)
                                )
                                .padding(horizontal = 8.dp, vertical = 4.dp)
                        )
                    }
                }
                Spacer(Modifier.width(12.dp))
                Icon(
                    if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,
                    if (expanded) "折叠" else "展开",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
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
                        verticalArrangement = Arrangement.spacedBy(3.dp)
                    ) {
                        module.children.forEachIndexed { index, child ->
                            ProgramModuleCard(
                                module = child,
                                position = materialGroupPosition(index, module.children.size)
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ScheduleSection(section: MaterialSection.Schedule, selectedDay: String?) {
    MaterialSectionBlock(section.title) {
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
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                visibleDays.forEach { day ->
                    if (day.lessons.isNotEmpty()) {
                        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Row(
                                Modifier.fillMaxWidth().padding(start = 8.dp, end = 8.dp, bottom = 5.dp),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    day.name,
                                    style = MaterialTheme.typography.labelLarge,
                                    fontWeight = FontWeight.SemiBold,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                                Text(
                                    "${day.lessons.size} 项",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            day.lessons.forEachIndexed { index, lesson ->
                                ScheduleLessonCard(
                                    item = lesson,
                                    position = materialGroupPosition(index, day.lessons.size)
                                )
                            }
                        }
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
private fun ScheduleLessonCard(
    item: MaterialCardItem,
    position: MaterialGroupPosition
) {
    val schedule = item.schedule
    MaterialPanel(position = position) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 15.dp),
            verticalAlignment = Alignment.Top
        ) {
            Column(
                modifier = Modifier.width(62.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp)
            ) {
                Text(
                    schedule?.startTime?.takeIf(String::isNotBlank)
                        ?: schedule?.startSection?.takeIf(String::isNotBlank)?.let { "$it 节" }
                        ?: "课程",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold
                )
                Text(
                    schedule?.endTime?.takeIf(String::isNotBlank)
                        ?: schedule?.endSection?.takeIf(String::isNotBlank)?.let { "至 $it 节" }
                        .orEmpty(),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            VerticalDivider(
                modifier = Modifier.heightIn(min = 56.dp).padding(horizontal = 12.dp),
                color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.62f)
            )
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Text(
                    item.title.ifBlank { "未命名课程" },
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )
                if (item.subtitle.isNotBlank()) {
                    Text(
                        item.subtitle,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                val details = listOfNotNull(
                    schedule?.location?.takeIf(String::isNotBlank),
                    schedule?.teacher?.takeIf(String::isNotBlank),
                    schedule?.weeks?.takeIf(String::isNotBlank)
                )
                if (details.isNotEmpty()) {
                    Text(
                        details.joinToString(" · "),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

@Composable
private fun CardsSection(section: MaterialSection.Cards) {
    MaterialSectionBlock(section.title) {
        if (section.cards.isEmpty()) {
            TextCard(MaterialSection.Text("", listOf("暂无数据")))
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                section.cards.forEachIndexed { index, item ->
                    MaterialInfoCard(
                        item = item,
                        position = materialGroupPosition(index, section.cards.size)
                    )
                }
            }
        }
    }
}

@Composable
private fun MaterialInfoCard(
    item: MaterialCardItem,
    position: MaterialGroupPosition = MaterialGroupPosition.ONLY
) {
    MaterialPanel(position = position) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 15.dp),
            verticalArrangement = Arrangement.spacedBy(11.dp)
        ) {
            Row(verticalAlignment = Alignment.Top) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(
                        item.title.ifBlank { "未命名项目" },
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold
                    )
                    if (item.subtitle.isNotBlank()) {
                        Text(
                            item.subtitle,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
                if (item.accent.isNotBlank()) {
                    Text(
                        item.accent,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier
                            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(10.dp))
                            .padding(horizontal = 10.dp, vertical = 6.dp)
                    )
                }
            }
            val fields = item.fields.filter { it.second.isNotBlank() }
            if (fields.isNotEmpty()) {
                HorizontalDivider(
                    color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.52f)
                )
                Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
                    fields.forEach { (label, value) ->
                        Row(
                            Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(14.dp),
                            verticalAlignment = Alignment.Top
                        ) {
                            Text(
                                label,
                                modifier = Modifier.width(82.dp),
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Text(
                                value,
                                modifier = Modifier.weight(1f),
                                style = MaterialTheme.typography.bodyMedium,
                                textAlign = TextAlign.End
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MaterialTable(section: MaterialSection.Table) {
    MaterialSectionBlock(section.title) {
        MaterialPanel(MaterialGroupPosition.ONLY) {
            Column(Modifier.padding(vertical = 8.dp)) {
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
}

@Composable
private fun TableRow(values: List<String>, header: Boolean, alternate: Boolean = false) {
    val rowColor = when {
        header -> MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.72f)
        alternate -> MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.32f)
        else -> Color.Transparent
    }
    Row(Modifier.background(rowColor)) {
        values.forEach { value ->
            Text(
                value.ifBlank { "—" },
                modifier = Modifier.width(148.dp).padding(horizontal = 12.dp, vertical = 11.dp),
                style = if (header) MaterialTheme.typography.labelLarge else MaterialTheme.typography.bodyMedium,
                fontWeight = if (header) FontWeight.SemiBold else FontWeight.Normal
            )
        }
    }
}

@Composable
private fun FieldCard(section: MaterialSection.Fields) {
    MaterialSectionBlock(section.title) {
        MaterialPanel(MaterialGroupPosition.ONLY) {
            Column(Modifier.padding(horizontal = 16.dp)) {
                section.fields.forEachIndexed { index, (label, value) ->
                    if (index > 0) {
                        HorizontalDivider(
                            color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.48f)
                        )
                    }
                    Row(
                        Modifier.fillMaxWidth().padding(vertical = 13.dp),
                        horizontalArrangement = Arrangement.spacedBy(16.dp),
                        verticalAlignment = Alignment.Top
                    ) {
                        Text(
                            label,
                            modifier = Modifier.weight(0.4f),
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Text(
                            value,
                            modifier = Modifier.weight(0.6f),
                            style = MaterialTheme.typography.bodyMedium,
                            textAlign = TextAlign.End
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun TextCard(section: MaterialSection.Text) {
    MaterialSectionBlock(section.title) {
        MaterialPanel(MaterialGroupPosition.ONLY) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                section.paragraphs.forEach { Text(it, style = MaterialTheme.typography.bodyMedium) }
            }
        }
    }
}

@Composable
private fun LinkCard(section: MaterialSection.Links, onOpenLink: (String, String) -> Unit) {
    MaterialSectionBlock(section.title) {
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            section.links.forEachIndexed { index, (title, url) ->
                MaterialPanel(
                    position = materialGroupPosition(index, section.links.size),
                    onClick = { onOpenLink(title, url) }
                ) {
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 15.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(title, Modifier.weight(1f), fontWeight = FontWeight.Medium)
                        Spacer(Modifier.size(8.dp))
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

@Composable
private fun MaterialSectionBlock(
    title: String,
    content: @Composable ColumnScope.() -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        if (title.isNotBlank()) {
            Text(
                title,
                modifier = Modifier.padding(start = 8.dp, bottom = 5.dp),
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        content()
    }
}

private fun materialGroupPosition(index: Int, size: Int): MaterialGroupPosition = when {
    size <= 1 -> MaterialGroupPosition.ONLY
    index == 0 -> MaterialGroupPosition.FIRST
    index == size - 1 -> MaterialGroupPosition.LAST
    else -> MaterialGroupPosition.MIDDLE
}

@Composable
private fun MaterialPanel(
    position: MaterialGroupPosition,
    onClick: (() -> Unit)? = null,
    containerColor: Color = PortalCardBackground,
    border: BorderStroke? = null,
    content: @Composable () -> Unit
) {
    val shape = when (position) {
        MaterialGroupPosition.ONLY -> RoundedCornerShape(18.dp)
        MaterialGroupPosition.FIRST -> RoundedCornerShape(
            topStart = 18.dp,
            topEnd = 18.dp,
            bottomStart = 6.dp,
            bottomEnd = 6.dp
        )
        MaterialGroupPosition.MIDDLE -> RoundedCornerShape(6.dp)
        MaterialGroupPosition.LAST -> RoundedCornerShape(
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
        colors = CardDefaults.cardColors(containerColor = containerColor),
        border = border,
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
    ) {
        content()
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
