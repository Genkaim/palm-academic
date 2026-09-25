package cn.edu.cupk.portalreader

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import androidx.activity.compose.BackHandler
import androidx.activity.ComponentActivity
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.imeAnimationSource
import androidx.compose.foundation.layout.imeAnimationTarget
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.PagerDefaults
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.School
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import kotlinx.coroutines.delay
import com.kyant.backdrop.Backdrop
import com.kyant.backdrop.backdrops.layerBackdrop
import com.kyant.backdrop.backdrops.rememberLayerBackdrop
import com.kyant.backdrop.drawBackdrop
import com.kyant.backdrop.effects.blur
import com.kyant.backdrop.effects.lens
import com.kyant.backdrop.effects.vibrancy
import com.kyant.backdrop.catalog.components.LiquidBottomTab
import com.kyant.backdrop.catalog.components.LiquidBottomTabs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import androidx.lifecycle.lifecycleScope
import kotlin.math.abs

class HomeActivity : PortalActivity() {
    private var notificationVersion by mutableIntStateOf(0)
    private val notificationSettingsLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { notificationVersion++ }
    private val schoolSelectionLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == android.app.Activity.RESULT_OK) {
            result.data?.getStringExtra(SchoolSelectionActivity.EXTRA_RESULT_SCHOOL_ID)
                ?.let(::switchSchool)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        useContinuousSystemBars()
        val persistentNotificationEnabled = PortalNotificationPreferences.preferences(this)
            .getBoolean(PortalNotificationPreferences.KEY_PERSISTENT_NOTIFICATION, false)
        setContent {
            PortalTheme {
                val school = remember { SchoolAdapterRepository.load(this) }
                val currentNotificationVersion = notificationVersion
                val animatedEntry = intent.getBooleanExtra(
                    EXTRA_NOTIFICATION_ENTRY_ANIMATION,
                    false
                ) || intent.getBooleanExtra(EXTRA_LOGIN_ENTRY_ANIMATION, false)
                val entryProgress = remember {
                    Animatable(if (animatedEntry) 0f else 1f)
                }
                val entryOffsetPx = with(LocalDensity.current) { 12.dp.toPx() }
                LaunchedEffect(animatedEntry) {
                    if (animatedEntry) {
                        entryProgress.animateTo(
                            targetValue = 1f,
                            animationSpec = tween(
                                durationMillis = 280,
                                easing = FastOutSlowInEasing
                            )
                        )
                    }
                }
                Box(
                    Modifier
                        .fillMaxSize()
                        .graphicsLayer {
                            alpha = entryProgress.value
                            val scale = 0.985f + 0.015f * entryProgress.value
                            scaleX = scale
                            scaleY = scale
                            translationY = entryOffsetPx * (1f - entryProgress.value)
                        }
                ) {
                    HomeContent(
                        school = school,
                        onOpenItem = ::openItem,
                        onOpenNotifications = {
                            notificationSettingsLauncher.launch(
                                Intent(this@HomeActivity, NotificationSettingsActivity::class.java)
                            )
                        },
                        onOpenBackgroundSupport = {
                            startActivity(Intent(this@HomeActivity, BackgroundSupportActivity::class.java))
                        },
                        onOpenSchoolSelection = {
                            schoolSelectionLauncher.launch(
                                Intent(this@HomeActivity, SchoolSelectionActivity::class.java)
                                    .putExtra(
                                        SchoolSelectionActivity.EXTRA_SELECTED_SCHOOL_ID,
                                        SchoolAdapterRepository.activeSchoolId()
                                    )
                                    .putExtra(SchoolSelectionActivity.EXTRA_REQUIRES_LOGIN, true)
                            )
                        },
                        onLogout = ::logout,
                        onSessionExpired = ::returnToLogin,
                        notificationVersion = currentNotificationVersion
                    )
                }
            }
        }
        // Starting the foreground service performs a synchronous preference commit and can
        // otherwise hold the launch activity before its first frame. Defer it off the UI
        // thread; the setting has already been persisted by the settings screen.
        if (persistentNotificationEnabled) {
            lifecycleScope.launch(Dispatchers.IO) {
                PortalKeepAliveService.setEnabled(applicationContext, true)
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
        PortalHttp.clearSession()
        PortalSessionCoordinator.clear()
        startActivity(
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        )
        finish()
    }

    private fun switchSchool(schoolId: String) {
        if (!SchoolAdapterRepository.select(this, schoolId)) return
        PortalMonitor.cancel(this)
        PortalSessionCoordinator.clear()
        PortalHttp.clearSession {
            startActivity(
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            )
            finish()
        }
    }

    private fun logout() {
        PortalMonitor.cancel(this)
        returnToLogin()
    }

    companion object {
        const val EXTRA_LOGIN_ENTRY_ANIMATION = "login_entry_animation"
        const val EXTRA_NOTIFICATION_ENTRY_ANIMATION = "notification_entry_animation"
    }
}

@Composable
private fun HomeContent(
    school: SchoolDefinition,
    onOpenItem: (PortalItem) -> Unit,
    onOpenNotifications: () -> Unit,
    onOpenBackgroundSupport: () -> Unit,
    onOpenSchoolSelection: () -> Unit,
    onLogout: () -> Unit,
    onSessionExpired: () -> Unit,
    notificationVersion: Int
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val sessionState by PortalSessionCoordinator.state.collectAsState()
    val notificationPreferences = remember { PortalNotificationPreferences.preferences(context) }
    val enabledNotificationCount = remember(notificationVersion) {
        PortalNotificationPreferences.enabledCount(notificationPreferences)
    }
    val pollHistoryVersion by PortalPollHistory.version.collectAsState()
    val pendingChangeNotice = remember(pollHistoryVersion) {
        PortalPollHistory.latestUnreadChange(context)
    }
    val pagerState = rememberPagerState(pageCount = { HomeDestination.entries.size })
    val pagerFlingBehavior = PagerDefaults.flingBehavior(
        state = pagerState,
        snapAnimationSpec = spring(dampingRatio = 0.92f, stiffness = 180f)
    )
    val navigationScope = rememberCoroutineScope()
    val destination = HomeDestination.entries[pagerState.currentPage]
    var searchExpanded by rememberSaveable { mutableStateOf(false) }
    var query by rememberSaveable { mutableStateOf("") }
    var automaticUpdateChecked by remember { mutableStateOf(false) }
    var baselinePrefetchReady by remember { mutableStateOf(false) }
    var availableRelease by remember { mutableStateOf<GitHubRelease?>(null) }
    LaunchedEffect(sessionState) {
        if (sessionState is PortalSessionState.Ready && !automaticUpdateChecked) {
            automaticUpdateChecked = true
            delay(1_500)
            runCatching { PalmAcademicGitHub.latestRelease() }
                .onSuccess { release ->
                    if (
                        release.isNewerThan(BuildConfig.VERSION_NAME) &&
                        PortalSessionCoordinator.state.value is PortalSessionState.Ready
                    ) {
                        availableRelease = release
                    }
                }
        }
    }
    LaunchedEffect(Unit) {
        delay(3_000)
        baselinePrefetchReady = true
    }
    val visibleGroups = remember(query, school) {
        school.groups.mapNotNull { group ->
            val items = group.items.filter { item ->
                !item.quick && (
                    query.isBlank() || item.title.contains(query.trim(), ignoreCase = true)
                )
            }
            if (items.isEmpty()) null else PortalGroup(group.title, items)
        }
    }
    val visibleQuickItems = remember(query, school) {
        school.quickItems.filter { query.isBlank() || it.title.contains(query.trim(), ignoreCase = true) }
    }
    val closeSearch = {
        searchExpanded = false
        query = ""
    }
    val navigateTo: (HomeDestination) -> Unit = { target ->
        navigationScope.launch {
            pagerState.animateScrollToPage(
                page = target.ordinal,
                animationSpec = tween(durationMillis = 280, easing = FastOutSlowInEasing)
            )
        }
    }
    LaunchedEffect(pagerState.settledPage) {
        if (pagerState.settledPage == HomeDestination.SETTINGS.ordinal && searchExpanded) {
            closeSearch()
        }
    }
    BackHandler(enabled = searchExpanded || destination == HomeDestination.SETTINGS) {
        if (searchExpanded) closeSearch() else navigateTo(HomeDestination.HOME)
    }
    val pageBackground = MaterialTheme.colorScheme.background
    val backdrop = rememberLayerBackdrop {
        drawRect(pageBackground)
        drawContent()
    }
    val navigationInset = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    val windowWidth = with(LocalDensity.current) {
        LocalWindowInfo.current.containerSize.width.toDp()
    }
    val horizontalContentPadding = if (windowWidth >= 600.dp) {
        32.dp
    } else {
        16.dp
    }
    Box(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
    ) {
        Scaffold(
            modifier = Modifier.layerBackdrop(backdrop),
            containerColor = Color.Transparent,
            topBar = {
                PortalGradientTopAppBar(
                    title = {
                        val titleSlideDistance = with(LocalDensity.current) { 12.dp.roundToPx() }
                        AnimatedContent(
                            targetState = destination,
                            transitionSpec = {
                                val movingForward = targetState == HomeDestination.SETTINGS
                                (
                                    fadeIn(tween(220), initialAlpha = 0f) + slideInHorizontally(tween(240)) {
                                        if (movingForward) titleSlideDistance else -titleSlideDistance
                                    }
                                )
                                    .togetherWith(
                                        fadeOut(tween(240), targetAlpha = 0f) + slideOutHorizontally(tween(220)) {
                                            if (movingForward) -titleSlideDistance else titleSlideDistance
                                        }
                                    )
                            },
                            label = "top-title"
                        ) { titleDestination ->
                            Column {
                                Text(
                                    if (titleDestination == HomeDestination.HOME) "掌上教务" else "设置",
                                    color = PortalInk,
                                    style = MaterialTheme.typography.headlineSmall,
                                    fontWeight = FontWeight.Bold
                                )
                                Text(
                                    if (titleDestination == HomeDestination.HOME) school.name else "个性化与应用管理",
                                    color = PortalInk.copy(alpha = 0.72f),
                                    style = MaterialTheme.typography.labelMedium
                                )
                            }
                        }
                    },
                    actions = {
                        if (destination == HomeDestination.HOME) {
                            PortalSessionStatus(
                                state = sessionState,
                                onRetry = { PortalSessionCoordinator.validate(context.applicationContext as android.app.Application, force = true) },
                                modifier = Modifier.padding(end = 12.dp)
                            )
                        }
                    }
                )
            }
        ) { padding ->
            HorizontalPager(
                state = pagerState,
                flingBehavior = pagerFlingBehavior,
                modifier = Modifier.fillMaxSize(),
                key = { page -> HomeDestination.entries[page] }
            ) { page ->
                val targetDestination = HomeDestination.entries[page]
                if (targetDestination == HomeDestination.HOME) {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(
                            start = horizontalContentPadding,
                            top = (padding.calculateTopPadding() - PortalTopFadeDepth).coerceAtLeast(0.dp) + 16.dp,
                            end = horizontalContentPadding,
                            bottom = padding.calculateBottomPadding() + navigationInset + 112.dp
                        ),
                        verticalArrangement = Arrangement.spacedBy(24.dp)
                    ) {
                        if (!searchExpanded || query.isBlank()) {
                            item {
                                HomeSection("状态") {
                                    HomeStatusPanel(
                                        enabledCount = enabledNotificationCount,
                                        notice = pendingChangeNotice,
                                        onNormalClick = onOpenNotifications,
                                        onNoticeClick = { notice ->
                                            school.quickItems
                                                .firstOrNull { it.nativeType == notice.nativeType }
                                                ?.let { target ->
                                                    PortalPollHistory.acknowledgeHomeChange(
                                                        context,
                                                        notice
                                                    )
                                                    onOpenItem(target)
                                                }
                                        }
                                    )
                                }
                            }
                        }
                        if (visibleQuickItems.isNotEmpty()) {
                            item {
                                HomeSection(if (searchExpanded) "搜索结果" else "常用功能") {
                                    QuickEntryGrid(
                                        items = visibleQuickItems,
                                        onOpenItem = onOpenItem
                                    )
                                }
                            }
                        }
                        visibleGroups.forEach { group ->
                            item {
                                HomeSection(group.title) {
                                    PortalItemCard(items = group.items, onOpenItem = onOpenItem)
                                }
                            }
                        }
                        if (
                            searchExpanded && query.isNotBlank() &&
                            visibleQuickItems.isEmpty() && visibleGroups.isEmpty()
                        ) {
                            item {
                                SearchMessage(
                                    icon = Icons.Outlined.Search,
                                    title = "没有找到相关功能",
                                    description = "换一个关键词试试"
                                )
                            }
                        }
                        item { Spacer(Modifier.height(8.dp)) }
                    }
                } else {
                    SettingsContent(
                        onNotifications = onOpenNotifications,
                        onBackgroundSupport = onOpenBackgroundSupport,
                        onOpenSchoolSelection = onOpenSchoolSelection,
                        onLogout = onLogout,
                        topPadding =
                            (padding.calculateTopPadding() - PortalTopFadeDepth).coerceAtLeast(0.dp) + 12.dp,
                        bottomPadding = navigationInset + 112.dp
                    )
                }
            }
        }
        FloatingHomeNavigation(
            backdrop = backdrop,
            destination = destination,
            searchExpanded = searchExpanded,
            query = query,
            onQueryChange = { query = it },
            onHome = {
                closeSearch()
                navigateTo(HomeDestination.HOME)
            },
            onSettings = {
                closeSearch()
                navigateTo(HomeDestination.SETTINGS)
            },
            onSearch = {
                if (destination == HomeDestination.SETTINGS) {
                    // Start focus/IME and the expanding search surface in the same frame as
                    // the pager transition instead of waiting for Home to finish settling.
                    searchExpanded = true
                    navigateTo(HomeDestination.HOME)
                } else {
                    searchExpanded = true
                }
            },
            onCloseSearch = closeSearch,
            modifier = Modifier.align(Alignment.BottomCenter)
        )
        QuickEntryBaselinePrefetch(
            school = school,
            active = baselinePrefetchReady && sessionState is PortalSessionState.Ready,
            onSessionExpired = {
                // A hidden adapter can briefly misclassify a loading/redirect page. Confirm the
                // session centrally before exposing any login UI or leaving Home.
                PortalSessionCoordinator.validate(
                    context.applicationContext as android.app.Application,
                    force = true
                )
            }
        )
    }
    if (sessionState is PortalSessionState.Expired) {
        AlertDialog(
            onDismissRequest = {},
            title = { Text("登录状态已失效") },
            text = { Text("上次保存的教务登录状态已过期，请重新登录。") },
            confirmButton = { Button(onClick = onSessionExpired) { Text("重新登录") } }
        )
    }
    if (sessionState is PortalSessionState.Ready) {
        availableRelease?.let { release ->
            AlertDialog(
                onDismissRequest = { availableRelease = null },
                title = { Text("发现新版本 ${release.tagName}") },
                text = {
                    Text(
                        release.notes.ifBlank { "新版本已发布，可前往 GitHub 下载更新。" }
                            .take(2000)
                    )
                },
                confirmButton = {
                    Button(onClick = {
                        availableRelease = null
                        context.startActivity(
                            Intent(Intent.ACTION_VIEW, Uri.parse(release.apkUrl ?: release.pageUrl))
                        )
                    }) { Text(if (release.apkUrl != null) "下载 APK" else "查看 Release") }
                },
                dismissButton = {
                    OutlinedButton(onClick = { availableRelease = null }) { Text("稍后") }
                }
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FloatingHomeNavigation(
    backdrop: Backdrop,
    destination: HomeDestination,
    searchExpanded: Boolean,
    query: String,
    onQueryChange: (String) -> Unit,
    onHome: () -> Unit,
    onSettings: () -> Unit,
    onSearch: () -> Unit,
    onCloseSearch: () -> Unit,
    modifier: Modifier = Modifier
) {
    val focusRequester = remember { FocusRequester() }
    val focusManager = LocalFocusManager.current
    val keyboardController = LocalSoftwareKeyboardController.current
    val hostView = LocalView.current
    val hostActivity = LocalActivity.current
    var keyboardReachedOpen by remember { mutableStateOf(false) }
    var hasOpenedSearch by remember { mutableStateOf(false) }
    var imeRequestPending by remember { mutableStateOf(false) }
    var visualSearchExpanded by remember { mutableStateOf(false) }
    LaunchedEffect(searchExpanded) {
        if (searchExpanded) {
            hasOpenedSearch = true
            keyboardReachedOpen = false
            imeRequestPending = true
            focusRequester.requestFocus()
            withFrameNanos { }
            keyboardController?.show()
            hostView.post {
                hostActivity?.let { activity ->
                    WindowCompat.getInsetsController(activity.window, hostView)
                        .show(WindowInsetsCompat.Type.ime())
                }
            }
            imeRequestPending = false
        } else {
            visualSearchExpanded = false
            imeRequestPending = false
            keyboardController?.hide()
            focusManager.clearFocus(force = true)
        }
    }
    val density = LocalDensity.current
    val imeBottom = WindowInsets.ime.getBottom(density)
    val imeAnimationSourceBottom = WindowInsets.imeAnimationSource.getBottom(density)
    val imeAnimationTargetBottom = WindowInsets.imeAnimationTarget.getBottom(density)
    val navigationBottomPx = WindowInsets.navigationBars.getBottom(density).toFloat()
    val baseBottomPx = navigationBottomPx + with(density) { 16.dp.toPx() }
    val restingExpandedLiftPx = with(density) { 72.dp.toPx() }
    val searchLiftAnimation = remember { Animatable(0f) }
    val imeAnimationRange = maxOf(
        imeBottom,
        imeAnimationSourceBottom,
        imeAnimationTargetBottom
    )
    val imeVisibleProgress = if (imeAnimationRange > 0) {
        (imeBottom.toFloat() / imeAnimationRange).coerceIn(0f, 1f)
    } else {
        0f
    }
    val fullyRaisedLiftPx = maxOf(
        restingExpandedLiftPx,
        imeAnimationRange.toFloat() + with(density) { 12.dp.toPx() } - baseBottomPx
    )
    val imeIsShowing = imeAnimationSourceBottom < imeAnimationTargetBottom
    val imeIsHiding = imeAnimationSourceBottom > imeAnimationTargetBottom
    LaunchedEffect(searchExpanded, imeIsShowing, imeBottom) {
        if (searchExpanded && (imeIsShowing || imeBottom > 0)) {
            visualSearchExpanded = true
        } else if (!searchExpanded) {
            visualSearchExpanded = false
        }
    }
    LaunchedEffect(searchExpanded) {
        if (searchExpanded) {
            // Hardware keyboards and IMEs without animated insets still need a usable field.
            delay(350)
            visualSearchExpanded = true
        }
    }
    val hiddenLiftPx = when {
        imeIsShowing && keyboardReachedOpen -> restingExpandedLiftPx
        imeIsShowing -> 0f
        imeIsHiding && keyboardReachedOpen -> restingExpandedLiftPx
        keyboardReachedOpen -> restingExpandedLiftPx
        else -> 0f
    }
    val imeSynchronizedLiftPx =
        hiddenLiftPx + (fullyRaisedLiftPx - hiddenLiftPx) * imeVisibleProgress

    LaunchedEffect(searchExpanded) {
        if (!searchExpanded) {
            keyboardReachedOpen = false
            if (hasOpenedSearch) {
                searchLiftAnimation.animateTo(
                    targetValue = 0f,
                    animationSpec = tween(durationMillis = 285, easing = FastOutSlowInEasing)
                )
            } else {
                searchLiftAnimation.snapTo(0f)
            }
        }
    }
    LaunchedEffect(
        searchExpanded,
        imeBottom,
        imeAnimationSourceBottom,
        imeAnimationTargetBottom,
        baseBottomPx,
        restingExpandedLiftPx
    ) {
        if (searchExpanded) {
            val singleFrameJump =
                imeAnimationRange > 0 && imeBottom == imeAnimationRange &&
                    abs(imeSynchronizedLiftPx - searchLiftAnimation.value) >
                    with(density) { 48.dp.toPx() }
            if (singleFrameJump) {
                searchLiftAnimation.animateTo(
                    targetValue = imeSynchronizedLiftPx,
                    animationSpec = tween(durationMillis = 240, easing = FastOutSlowInEasing)
                )
            } else {
                searchLiftAnimation.snapTo(imeSynchronizedLiftPx)
            }
            if (!imeIsShowing && imeBottom > 0) {
                keyboardReachedOpen = true
            }
        }
    }
    // Some IMEs publish only a few animation frames. The interpolated value can then trail the
    // real keyboard edge for a frame, so clamp the rendered position above the current IME top.
    val imeSafeLiftPx = if (imeBottom > 0) {
        (imeBottom.toFloat() + with(density) { 12.dp.toPx() } - baseBottomPx)
            .coerceAtLeast(0f)
    } else {
        0f
    }
    val renderedSearchLiftPx = maxOf(searchLiftAnimation.value, imeSafeLiftPx)
    val searchLiftOffset = with(density) { renderedSearchLiftPx.toDp() }
    val searchWidth by animateDpAsState(
        targetValue = if (visualSearchExpanded) 284.dp else 64.dp,
        animationSpec = spring(dampingRatio = 0.82f, stiffness = 440f),
        label = "search-width"
    )
    val searchHorizontalOffset by animateDpAsState(
        targetValue = if (visualSearchExpanded) 0.dp else 110.dp,
        animationSpec = spring(dampingRatio = 0.82f, stiffness = 440f),
        label = "search-horizontal-offset"
    )
    val searchIconOffset = -(searchWidth / 2 - 32.dp)
    val searchFieldAlpha by animateFloatAsState(
        targetValue = if (visualSearchExpanded) 1f else 0f,
        animationSpec = tween(durationMillis = 150, easing = FastOutSlowInEasing),
        label = "search-field-alpha"
    )
    val glassEnabled = PortalThemePreferences.glassEnabled
    val glassTint = MaterialTheme.colorScheme.surface.copy(alpha = 0.64f)
    val navigationTabsWidth by animateDpAsState(
        targetValue = if (visualSearchExpanded) 284.dp else 210.dp,
        animationSpec = spring(dampingRatio = 0.82f, stiffness = 440f),
        label = "navigation-tabs-width"
    )
    val navigationSearchSlotWidth by animateDpAsState(
        targetValue = if (visualSearchExpanded) 0.dp else 64.dp,
        animationSpec = spring(dampingRatio = 0.82f, stiffness = 440f),
        label = "navigation-search-slot-width"
    )
    val navigationGap by animateDpAsState(
        targetValue = if (visualSearchExpanded) 0.dp else 10.dp,
        animationSpec = spring(dampingRatio = 0.82f, stiffness = 440f),
        label = "navigation-gap"
    )
    val searchShape = RoundedCornerShape(32.dp)
    Box(modifier = modifier.fillMaxSize()) {
        Row(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .wrapContentWidth()
                .navigationBarsPadding()
                .padding(start = 16.dp, end = 16.dp, bottom = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(navigationGap),
            verticalAlignment = Alignment.CenterVertically
        ) {
            LiquidBottomTabs(
                selectedTabIndex = {
                    if (destination == HomeDestination.HOME) 0 else 1
                },
                onTabSelected = { index -> if (index == 0) onHome() else onSettings() },
                backdrop = backdrop,
                tabsCount = 2,
                glassEnabled = glassEnabled,
                modifier = Modifier.width(navigationTabsWidth)
            ) {
                LiquidBottomTab(onClick = onHome) {
                    BottomTabContent(Icons.Outlined.Home, "主页")
                }
                LiquidBottomTab(onClick = onSettings) {
                    BottomTabContent(Icons.Outlined.Settings, "设置")
                }
            }
            Spacer(Modifier.width(navigationSearchSlotWidth).height(64.dp))
        }
        val searchSurfaceModifier = if (glassEnabled) {
            Modifier.drawBackdrop(
                backdrop = backdrop,
                shape = { searchShape },
                effects = {
                    vibrancy()
                    blur(8.dp.toPx())
                    lens(24.dp.toPx(), 24.dp.toPx())
                },
                onDrawSurface = { drawRect(glassTint) }
            )
        } else {
            Modifier
                .shadow(
                    elevation = 10.dp,
                    shape = searchShape,
                    ambientColor = Color.Black.copy(alpha = 0.12f),
                    spotColor = Color.Black.copy(alpha = 0.16f)
                )
                .clip(searchShape)
                .background(MaterialTheme.colorScheme.surface)
        }
        Box(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = 16.dp)
        ) {
            Box(
                modifier = Modifier
                    .offset {
                        IntOffset(
                            x = searchHorizontalOffset.roundToPx(),
                            y = -searchLiftOffset.roundToPx()
                        )
                    }
                    .width(searchWidth)
                    .height(64.dp)
                    .then(searchSurfaceModifier)
                    .clip(searchShape),
                contentAlignment = Alignment.Center
            ) {
                OutlinedTextField(
                    value = query,
                    onValueChange = onQueryChange,
                    modifier = Modifier
                        .fillMaxSize()
                        .focusRequester(focusRequester)
                        .onFocusChanged { focusState ->
                            if (focusState.isFocused && imeRequestPending) {
                                imeRequestPending = false
                                keyboardController?.show()
                                hostView.post {
                                    hostActivity?.let { activity ->
                                        WindowCompat.getInsetsController(activity.window, hostView)
                                            .show(WindowInsetsCompat.Type.ime())
                                    }
                                }
                            }
                        }
                        .graphicsLayer { alpha = searchFieldAlpha },
                    singleLine = true,
                    leadingIcon = {
                        Spacer(Modifier.size(23.dp))
                    },
                    trailingIcon = {
                        IconButton(onClick = onCloseSearch) {
                            Icon(Icons.Outlined.Close, "关闭搜索")
                        }
                    },
                    placeholder = { Text("搜索教务功能") },
                    shape = searchShape,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedContainerColor = Color.Transparent,
                        unfocusedContainerColor = Color.Transparent,
                        focusedBorderColor = Color.Transparent,
                        unfocusedBorderColor = Color.Transparent
                    )
                )
                Icon(
                    Icons.Outlined.Search,
                    contentDescription = "搜索",
                    tint = PortalInk,
                    modifier = Modifier.offset(x = searchIconOffset).size(23.dp)
                )
                if (!searchExpanded) {
                    Box(
                        modifier = Modifier.fillMaxSize().clickable {
                            if (destination == HomeDestination.HOME) {
                                imeRequestPending = true
                                focusRequester.requestFocus()
                                onSearch()
                                hostView.post {
                                    keyboardController?.show()
                                    hostActivity?.let { activity ->
                                        WindowCompat.getInsetsController(activity.window, hostView)
                                            .show(WindowInsetsCompat.Type.ime())
                                    }
                                }
                            } else {
                                onSearch()
                            }
                        }
                    )
                }
            }
        }
    }
}

private enum class HomeDestination { HOME, SETTINGS }
private enum class HomeGroupPosition { ONLY, FIRST, MIDDLE, LAST }

@Composable
private fun BottomTabContent(icon: ImageVector, label: String) {
    val contentColor = MaterialTheme.colorScheme.onSurface
    Icon(icon, label, tint = contentColor, modifier = Modifier.size(21.dp))
    Text(
        label,
        style = MaterialTheme.typography.labelSmall.copy(fontSize = 10.sp, lineHeight = 11.sp),
        fontWeight = FontWeight.Medium,
        color = contentColor
    )
}

@Composable
private fun PortalItemCard(items: List<PortalItem>, onOpenItem: (PortalItem) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        items.forEachIndexed { index, item ->
            HomePanel(
                position = when {
                    items.size == 1 -> HomeGroupPosition.ONLY
                    index == 0 -> HomeGroupPosition.FIRST
                    index == items.lastIndex -> HomeGroupPosition.LAST
                    else -> HomeGroupPosition.MIDDLE
                },
                onClick = { onOpenItem(item) }
            ) {
                PortalRow(item)
            }
        }
    }
}

@Composable
private fun SearchMessage(icon: ImageVector, title: String, description: String) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 56.dp, horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Icon(
            icon,
            contentDescription = null,
            modifier = Modifier.size(40.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Text(
            description,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
private fun QuickEntryBaselinePrefetch(
    school: SchoolDefinition,
    active: Boolean,
    onSessionExpired: () -> Unit
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val items = remember(school) { orderedQuickBaselineItems(school.quickItems) }
    var pending by remember(school.id) {
        mutableStateOf(QuickEntryBaseline.isPending(context, school.id))
    }
    var itemIndex by remember(school.id) { mutableIntStateOf(0) }
    var previousFailure by remember(school.id) { mutableStateOf(false) }
    var snapshots by remember(school.id) {
        mutableStateOf(emptyList<QuickEntryBaselineSnapshot>())
    }

    if (!active || !pending || items.isEmpty() || itemIndex !in items.indices) return
    val adapterScript = remember(school.adapterAsset) {
        SchoolAdapterRepository.readAdapterScript(context, school.adapterAsset)
    }
    val item = items[itemIndex]
    key(item.url) {
        var itemFinished by remember { mutableStateOf(false) }
        var latestSnapshot by remember { mutableStateOf<QuickEntryBaselineSnapshot?>(null) }
        var publicationVersion by remember { mutableIntStateOf(0) }
        val startedAt = remember { SystemClock.elapsedRealtime() }
        val finishItem: (QuickEntryBaselineSnapshot?) -> Unit = finish@{ snapshot ->
            if (itemFinished) return@finish
            itemFinished = true
            val updatedSnapshots = snapshot?.let { snapshots + it } ?: snapshots
            val anyFailure = previousFailure || snapshot == null
            if (itemIndex == items.lastIndex) {
                if (!anyFailure && items.size == 4) {
                    QuickEntryBaseline.recordAndComplete(
                        context = context,
                        schoolId = school.id,
                        snapshots = updatedSnapshots
                    )
                }
                pending = false
            } else {
                snapshots = updatedSnapshots
                previousFailure = anyFailure
                itemIndex++
            }
        }
        LaunchedEffect(item.url) {
            delay(30_000)
            finishItem(null)
        }
        LaunchedEffect(item.url, publicationVersion) {
            val candidate = latestSnapshot ?: return@LaunchedEffect
            // Adapters commonly publish an empty DOM skeleton first and fill it after AJAX.
            // Keep the latest publication and wait for both a minimum load window and a quiet
            // period. Truly empty schedules/exams are accepted after the longer stable window.
            val minimumLoadMillis = if (
                quickBaselineHasData(candidate.page, item.nativeType)
            ) 4_000L else 10_000L
            val remainingMinimum = (
                minimumLoadMillis - (SystemClock.elapsedRealtime() - startedAt)
            ).coerceAtLeast(0L)
            delay(maxOf(2_000L, remainingMinimum))
            finishItem(candidate)
        }
        WebMaterialReader(
            url = item.url,
            adapterScript = adapterScript,
            schoolConfigJson = school.readerConfigJson,
            refreshToken = 0,
            action = null,
            modifier = Modifier.size(1.dp).alpha(0.01f),
            onLoading = {},
            onContent = { page ->
                val rawJson = MaterialPageCache.loadRaw(context, item.url)
                rawJson?.let {
                    latestSnapshot = QuickEntryBaselineSnapshot(
                        item = item,
                        page = page,
                        rawJson = it
                    )
                    publicationVersion++
                }
            },
            onError = { finishItem(null) },
            onSessionExpired = onSessionExpired
        )
    }
}

@Composable
private fun HomeSection(text: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(
            text,
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(start = 8.dp, bottom = 5.dp)
        )
        content()
    }
}

@Composable
private fun HomePanel(
    position: HomeGroupPosition,
    onClick: (() -> Unit)? = null,
    containerColor: Color = PortalCardBackground,
    content: @Composable () -> Unit
) {
    val shape = when (position) {
        HomeGroupPosition.ONLY -> RoundedCornerShape(18.dp)
        HomeGroupPosition.FIRST -> RoundedCornerShape(
            topStart = 18.dp,
            topEnd = 18.dp,
            bottomStart = 6.dp,
            bottomEnd = 6.dp
        )
        HomeGroupPosition.MIDDLE -> RoundedCornerShape(6.dp)
        HomeGroupPosition.LAST -> RoundedCornerShape(
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
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
    ) {
        content()
    }
}

@Composable
private fun QuickEntryGrid(
    items: List<PortalItem>,
    onOpenItem: (PortalItem) -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = PortalCardBackground),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
        shape = RoundedCornerShape(20.dp)
    ) {
        Column {
            items.chunked(2).forEachIndexed { rowIndex, rowItems ->
                if (rowIndex > 0) {
                    HorizontalDivider(
                        modifier = Modifier.padding(horizontal = 14.dp),
                        color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.55f)
                    )
                }
                Row(Modifier.fillMaxWidth().height(104.dp)) {
                    QuickEntryCell(
                        item = rowItems.first(),
                        modifier = Modifier.weight(1f).fillMaxHeight(),
                        onClick = { onOpenItem(rowItems.first()) }
                    )
                    VerticalDivider(
                        modifier = Modifier.fillMaxHeight().padding(vertical = 14.dp),
                        color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.55f)
                    )
                    val second = rowItems.getOrNull(1)
                    if (second != null) {
                        QuickEntryCell(
                            item = second,
                            modifier = Modifier.weight(1f).fillMaxHeight(),
                            onClick = { onOpenItem(second) }
                        )
                    } else {
                        Spacer(Modifier.weight(1f))
                    }
                }
            }
        }
    }
}

@Composable
private fun QuickEntryCell(
    item: PortalItem,
    modifier: Modifier = Modifier,
    onClick: () -> Unit
) {
    val icon: ImageVector = when {
        item.title.contains("课表") -> Icons.Outlined.CalendarMonth
        item.title.contains("考试") -> Icons.Outlined.Description
        item.title.contains("成绩") -> Icons.Outlined.School
        else -> Icons.Outlined.Search
    }
    Column(
        modifier = modifier
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.SpaceBetween
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.size(24.dp)
        )
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                item.title,
                fontWeight = FontWeight.SemiBold,
                style = MaterialTheme.typography.bodyMedium
            )
            Text(
                quickEntrySubtitle(item),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.labelSmall,
                maxLines = 1
            )
        }
    }
}

private fun quickEntrySubtitle(item: PortalItem): String = when (item.nativeType) {
    "schedule" -> "课程与时间"
    "grade" -> "成绩与绩点"
    "exam" -> "时间与考场"
    "program" -> "学分与进度"
    else -> "打开功能"
}

@Composable
private fun HomeStatusPanel(
    enabledCount: Int,
    notice: PortalHomeChangeNotice?,
    onNormalClick: () -> Unit,
    onNoticeClick: (PortalHomeChangeNotice) -> Unit
) {
    AnimatedContent(
        targetState = notice,
        transitionSpec = {
            fadeIn(tween(180, easing = FastOutSlowInEasing))
                .togetherWith(fadeOut(tween(120)))
        },
        contentKey = { it?.nativeType ?: "monitoring" },
        label = "home-status"
    ) { currentNotice ->
        val highlighted = currentNotice != null
        val foreground = if (highlighted) {
            MaterialTheme.colorScheme.onPrimary
        } else {
            MaterialTheme.colorScheme.onSurface
        }
        val secondaryForeground = if (highlighted) {
            MaterialTheme.colorScheme.onPrimary.copy(alpha = 0.76f)
        } else {
            MaterialTheme.colorScheme.onSurfaceVariant
        }
        HomePanel(
            position = HomeGroupPosition.ONLY,
            onClick = {
                if (currentNotice == null) onNormalClick() else onNoticeClick(currentNotice)
            },
            containerColor = if (highlighted) {
                MaterialTheme.colorScheme.primary
            } else {
                PortalCardBackground
            }
        ) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 15.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    Icons.Outlined.Notifications,
                    contentDescription = null,
                    tint = foreground,
                    modifier = Modifier.size(22.dp)
                )
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        if (currentNotice == null) "变动通知" else "${currentNotice.category}有新变化",
                        color = foreground,
                        fontWeight = FontWeight.SemiBold
                    )
                    Text(
                        when {
                            currentNotice != null -> "点击查看最新${currentNotice.category}信息"
                            enabledCount == 0 -> "课表、成绩与考试提醒均已关闭"
                            else -> "后台检测运行中"
                        },
                        color = secondaryForeground,
                        style = MaterialTheme.typography.bodySmall
                    )
                }
                if (currentNotice == null) {
                    Text(
                        if (enabledCount == 0) "未开启" else "$enabledCount 项",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier
                            .background(
                                MaterialTheme.colorScheme.surfaceVariant,
                                RoundedCornerShape(9.dp)
                            )
                            .padding(horizontal = 9.dp, vertical = 5.dp)
                    )
                    Spacer(Modifier.width(8.dp))
                }
                Icon(
                    Icons.Outlined.ChevronRight,
                    contentDescription = null,
                    tint = secondaryForeground,
                    modifier = Modifier.size(20.dp)
                )
            }
        }
    }
}

@Composable
private fun PortalRow(item: PortalItem) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 15.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            item.title,
            style = MaterialTheme.typography.bodyLarge,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.weight(1f)
        )
        Icon(Icons.Outlined.ChevronRight, null, tint = MaterialTheme.colorScheme.outline)
    }
}
