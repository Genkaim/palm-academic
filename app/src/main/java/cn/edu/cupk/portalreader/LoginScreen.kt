package cn.edu.cupk.portalreader

import android.graphics.BitmapFactory
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateIntAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.imeAnimationSource
import androidx.compose.foundation.layout.imeAnimationTarget
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AccountCircle
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.OpenInBrowser
import androidx.compose.material.icons.outlined.Phone
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.School
import androidx.compose.material.icons.outlined.Sms
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldColors
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.colorResource
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.kyant.backdrop.Backdrop
import com.kyant.backdrop.backdrops.layerBackdrop
import com.kyant.backdrop.backdrops.rememberLayerBackdrop

private val LoginPillShape = RoundedCornerShape(percent = 50)
private val LoginTextFieldHeight = 64.dp

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun RefactoredLoginContent(
    model: LoginViewModel,
    openWebLogin: () -> Unit,
    openSchoolSelection: () -> Unit
) {
    var username by remember { mutableStateOf(model.rememberedCredential?.username.orEmpty()) }
    var password by remember { mutableStateOf(model.rememberedCredential?.password.orEmpty()) }
    var captcha by remember { mutableStateOf("") }
    var rememberPassword by remember { mutableStateOf(model.rememberedCredential != null) }
    var revealPassword by remember { mutableStateOf(false) }
    var restingContentHeightPx by remember { mutableStateOf(0) }
    val passwordFocusRequester = remember { FocusRequester() }
    val captchaFocusRequester = remember { FocusRequester() }
    val focusManager = LocalFocusManager.current
    val listState = rememberLazyListState()
    val density = LocalDensity.current
    val imeBottom = WindowInsets.ime.getBottom(density)
    val imeSourceBottom = WindowInsets.imeAnimationSource.getBottom(density)
    val imeTargetBottom = WindowInsets.imeAnimationTarget.getBottom(density)
    val navigationBottom = WindowInsets.navigationBars.getBottom(density)
    val imeContentLiftPx = (imeBottom - navigationBottom).coerceAtLeast(0).toFloat()
    val imeContentLiftRangePx = (
        maxOf(imeBottom, imeSourceBottom, imeTargetBottom) - navigationBottom
    ).coerceAtLeast(0).toFloat()
    val imeProgress = if (imeContentLiftRangePx > 0f) {
        (imeContentLiftPx / imeContentLiftRangePx).coerceIn(0f, 1f)
    } else {
        0f
    }
    val secondaryActionAlpha = (1f - imeProgress * 2f).coerceIn(0f, 1f)
    val loginRestingBottomOffsetPx = with(density) { 82.dp.toPx() }
    val loginKeyboardSlotCompensationPx = with(density) { 62.dp.toPx() } * imeProgress
    val loginTranslationYPx = -loginRestingBottomOffsetPx + loginKeyboardSlotCompensationPx
    val keyboardVisible = imeSourceBottom <= imeTargetBottom &&
        maxOf(imeBottom, imeTargetBottom) > 0
    val selectedSchoolName = model.schoolOptions
        .firstOrNull { it.id == model.selectedSchoolId }
        ?.name
        .orEmpty()
    LaunchedEffect(model.selectedSchoolId, model.hasSelectedSchool) {
        username = model.rememberedCredential?.username.orEmpty()
        password = model.rememberedCredential?.password.orEmpty()
        captcha = ""
        rememberPassword = model.rememberedCredential != null
        if (model.captchaRequired && model.captchaImage == null && !model.captchaLoading) {
            model.refreshCaptcha()
        }
    }
    LaunchedEffect(model.captchaGeneration) {
        captcha = ""
    }
    LaunchedEffect(keyboardVisible) {
        if (!keyboardVisible) {
            listState.scrollToItem(0)
        }
    }
    val updateRememberPassword: (Boolean) -> Unit = { checked ->
        if (!model.loading) {
            rememberPassword = checked
            if (!checked) model.forgetPassword()
        }
    }

    val fieldColors = TextFieldDefaults.colors(
        focusedContainerColor = MaterialTheme.colorScheme.surface,
        unfocusedContainerColor = MaterialTheme.colorScheme.surface,
        disabledContainerColor = MaterialTheme.colorScheme.surface,
        focusedIndicatorColor = Color.Transparent,
        unfocusedIndicatorColor = Color.Transparent,
        disabledIndicatorColor = Color.Transparent,
        focusedTextColor = MaterialTheme.colorScheme.onSurface,
        unfocusedTextColor = MaterialTheme.colorScheme.onSurface,
        focusedLabelColor = MaterialTheme.colorScheme.onSurfaceVariant,
        unfocusedLabelColor = MaterialTheme.colorScheme.onSurfaceVariant,
        focusedLeadingIconColor = MaterialTheme.colorScheme.onSurface,
        unfocusedLeadingIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
        cursorColor = MaterialTheme.colorScheme.onSurface
    )

    val pageBackground = MaterialTheme.colorScheme.background
    val glassBackdrop = rememberLayerBackdrop {
        drawRect(pageBackground)
        drawContent()
    }
    Box(Modifier.fillMaxSize()) {
        Box(
            Modifier
                .fillMaxSize()
                .background(pageBackground)
                .layerBackdrop(glassBackdrop)
        )
        BoxWithConstraints(
            Modifier
                .fillMaxSize()
                .safeDrawingPadding()
        ) {
        val currentContentHeightPx = constraints.maxHeight
        LaunchedEffect(keyboardVisible, imeBottom, currentContentHeightPx) {
            if (!keyboardVisible && imeBottom == 0 && currentContentHeightPx > 0) {
                restingContentHeightPx = currentContentHeightPx
            }
        }
        val stationaryOffsetPx =
            (restingContentHeightPx - currentContentHeightPx).coerceAtLeast(0).toFloat()
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize().imePadding(),
            contentPadding = PaddingValues(
                start = 20.dp,
                top = if (model.hasSelectedSchool) 24.dp else 64.dp,
                end = 20.dp,
                bottom = if (model.hasSelectedSchool) 218.dp else 112.dp
            ),
            verticalArrangement = Arrangement.spacedBy(18.dp)
        ) {
            item(key = "login-brand") {
                AnimatedVisibility(
                    visible = !keyboardVisible,
                    enter = fadeIn(tween(220, easing = FastOutSlowInEasing)) + expandVertically(
                        animationSpec = tween(420, easing = FastOutSlowInEasing),
                        expandFrom = Alignment.Top
                    ),
                    exit = fadeOut(tween(200, easing = FastOutSlowInEasing)) + shrinkVertically(
                        animationSpec = tween(460, easing = FastOutSlowInEasing),
                        shrinkTowards = Alignment.Top
                    )
                ) {
                    // Compact brand lock-up aligned with iOS: a 28dp app-icon mark and the title
                    // on ONE leading row (was a centered 88dp hero above a displaySmall title).
                    // Only the mark/title size and placement change; nothing else on this screen.
                    //
                    // The mark is the LAUNCHER ICON ITSELF: the adaptive icon's pale background
                    // (R.color.launcher_background) plus its vector foreground, drawn to the same
                    // 108dp canvas so the centered circle+book glyph sits exactly where it does on
                    // the home screen. R.mipmap.ic_launcher cannot be used directly: it is an
                    // <adaptive-icon> XML and Compose painterResource only accepts VectorDrawables
                    // or raster images ("...asset types are supported" crash).
                    Row(
                        modifier = Modifier.fillMaxWidth().height(48.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Box(
                            modifier = Modifier
                                .size(28.dp)
                                .clip(RoundedCornerShape(7.dp))
                                .background(colorResource(R.color.launcher_background)),
                            contentAlignment = Alignment.Center
                        ) {
                            Image(
                                painter = painterResource(R.drawable.ic_launcher_foreground),
                                contentDescription = "掌上教务标识",
                                contentScale = ContentScale.Fit,
                                modifier = Modifier.fillMaxSize()
                            )
                        }
                        Spacer(Modifier.size(10.dp))
                        Text(
                            "掌上教务",
                            style = MaterialTheme.typography.titleMedium,
                            fontSize = 19.sp,
                            color = MaterialTheme.colorScheme.onBackground,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }
            }

            if (model.hasSelectedSchool) {
                item(key = "password-form") {
                    val scriptLogin = model.scriptLogin
                    if (scriptLogin != null) {
                        // 脚本学校：沿用同一个登录页骨架，只把数据源换成 schema 驱动的
                        // 控制器；多方式切换/短信/扫码/弹窗是仅此处新增的控件。
                        ScriptLoginFormSection(scriptLogin, fieldColors, glassBackdrop)
                    } else {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            LoginFormLabel("密码登录")
                            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                TextField(
                                    value = username,
                                    onValueChange = { username = it },
                                    label = { Text("学号 / 账号") },
                                    leadingIcon = { Icon(Icons.Outlined.AccountCircle, null) },
                                    singleLine = true,
                                    keyboardOptions = KeyboardOptions(
                                        keyboardType = KeyboardType.Text,
                                        imeAction = ImeAction.Next
                                    ),
                                    keyboardActions = KeyboardActions(
                                        onNext = { passwordFocusRequester.requestFocus() }
                                    ),
                                    shape = RoundedCornerShape(
                                        topStart = 18.dp,
                                        topEnd = 18.dp,
                                        bottomStart = 6.dp,
                                        bottomEnd = 6.dp
                                    ),
                                    colors = fieldColors,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .height(LoginTextFieldHeight)
                                )
                                TextField(
                                    value = password,
                                    onValueChange = { password = it },
                                    label = { Text("密码") },
                                    leadingIcon = { Icon(Icons.Outlined.Key, null) },
                                    trailingIcon = {
                                        IconButton(onClick = { revealPassword = !revealPassword }) {
                                            Icon(
                                                if (revealPassword) {
                                                    Icons.Outlined.VisibilityOff
                                                } else {
                                                    Icons.Outlined.Visibility
                                                },
                                                if (revealPassword) "隐藏密码" else "显示密码"
                                            )
                                        }
                                    },
                                    singleLine = true,
                                    visualTransformation = if (revealPassword) {
                                        VisualTransformation.None
                                    } else {
                                        PasswordVisualTransformation()
                                    },
                                    keyboardOptions = KeyboardOptions(
                                        keyboardType = KeyboardType.Password,
                                        imeAction = if (model.captchaRequired) ImeAction.Next else ImeAction.Done
                                    ),
                                    keyboardActions = KeyboardActions(
                                        onNext = { captchaFocusRequester.requestFocus() },
                                        onDone = {
                                            if (username.isNotBlank() && password.isNotBlank()) {
                                                focusManager.clearFocus()
                                                model.login(username, password, rememberPassword, captcha)
                                            }
                                        }
                                    ),
                                    shape = RoundedCornerShape(
                                        topStart = 6.dp,
                                        topEnd = 6.dp,
                                        bottomStart = if (model.captchaRequired) 6.dp else 18.dp,
                                        bottomEnd = if (model.captchaRequired) 6.dp else 18.dp
                                    ),
                                    colors = fieldColors,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .height(LoginTextFieldHeight)
                                        .focusRequester(passwordFocusRequester)
                                )
                                if (model.captchaRequired) {
                                    TextField(
                                        value = captcha,
                                        onValueChange = { captcha = it },
                                        label = { Text("验证码") },
                                        leadingIcon = { Icon(Icons.Outlined.Lock, null) },
                                        trailingIcon = {
                                            Box(
                                                modifier = Modifier
                                                    .padding(end = 8.dp)
                                                    .size(width = 112.dp, height = 48.dp)
                                                    .clip(RoundedCornerShape(8.dp))
                                                    .clickable(
                                                        enabled = !model.captchaLoading && !model.loading
                                                    ) { model.refreshCaptcha() },
                                                contentAlignment = Alignment.Center
                                            ) {
                                                when {
                                                    model.captchaLoading -> CircularProgressIndicator(
                                                        modifier = Modifier.size(20.dp),
                                                        strokeWidth = 2.dp
                                                    )
                                                    model.captchaImage != null -> {
                                                        val bytes = model.captchaImage!!
                                                        val bitmap = remember(bytes) {
                                                            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                                                        }
                                                        if (bitmap != null) {
                                                            Image(
                                                                bitmap = bitmap.asImageBitmap(),
                                                                contentDescription = "验证码图片，点按刷新",
                                                                contentScale = ContentScale.Fit,
                                                                modifier = Modifier.fillMaxSize()
                                                            )
                                                        }
                                                    }
                                                    else -> Icon(
                                                        Icons.Outlined.Refresh,
                                                        contentDescription = model.captchaError ?: "刷新验证码"
                                                    )
                                                }
                                            }
                                        },
                                        singleLine = true,
                                        keyboardOptions = KeyboardOptions(
                                            keyboardType = KeyboardType.Text,
                                            imeAction = ImeAction.Done
                                        ),
                                        keyboardActions = KeyboardActions(onDone = {
                                            if (username.isNotBlank() && password.isNotBlank() &&
                                                captcha.isNotBlank() && model.captchaImage != null
                                            ) {
                                                focusManager.clearFocus()
                                                model.login(username, password, rememberPassword, captcha)
                                            }
                                        }),
                                        shape = RoundedCornerShape(
                                            topStart = 6.dp,
                                            topEnd = 6.dp,
                                            bottomStart = 18.dp,
                                            bottomEnd = 18.dp
                                        ),
                                        colors = fieldColors,
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .height(LoginTextFieldHeight)
                                            .focusRequester(captchaFocusRequester)
                                    )
                                }
                            }

                            Card(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(LoginPillShape),
                                shape = LoginPillShape,
                                colors = CardDefaults.cardColors(containerColor = PortalCardBackground),
                                elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
                            ) {
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(horizontal = 16.dp, vertical = 10.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Box(
                                        modifier = Modifier
                                            .weight(1f)
                                            .height(48.dp)
                                            .clickable(enabled = !model.loading) {
                                                updateRememberPassword(!rememberPassword)
                                            },
                                        contentAlignment = Alignment.CenterStart
                                    ) {
                                        Text("记住密码", fontWeight = FontWeight.Medium)
                                    }
                                    PortalGlassSwitch(
                                        checked = rememberPassword,
                                        onCheckedChange = updateRememberPassword,
                                        backdrop = glassBackdrop,
                                        label = "记住密码"
                                    )
                                }
                            }

                            // 输入框下方的错误提示不加底色，仅用错误色小字。
                            model.error?.let { message ->
                                Text(
                                    message,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(horizontal = 4.dp, vertical = 2.dp),
                                    color = MaterialTheme.colorScheme.error,
                                    style = MaterialTheme.typography.bodyMedium
                                )
                            }

                            // Non-terminal: a network-caused attempt is being retried. This is
                            // information, not an error -- the login keeps going by itself.
                            // 同样不加底色：仅转圈 + 次级文字。
                            model.retryStatus?.let { message ->
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(horizontal = 4.dp, vertical = 2.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                                ) {
                                    CircularProgressIndicator(
                                        modifier = Modifier.size(16.dp),
                                        strokeWidth = 2.dp
                                    )
                                    Text(
                                        message,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        style = MaterialTheme.typography.bodyMedium
                                    )
                                }
                            }
                    }
                    }
                }
            }
        }

        if (!model.hasSelectedSchool) {
            SchoolSelectionPrompt(
                modifier = Modifier.align(Alignment.BottomCenter),
                loading = model.loading,
                onSelectSchool = openSchoolSelection
            )
        } else {
            val scriptLogin = model.scriptLogin
            val scriptMethod = scriptLogin?.currentMethod()
            val pageLoading = scriptLogin?.let {
                it.busy || it.phase == ScriptLoginController.Phase.LOADING
            } ?: model.loading
            LoginSecondaryActions(
                modifier = Modifier.align(Alignment.BottomCenter),
                selectedSchoolName = selectedSchoolName,
                loading = pageLoading,
                secondaryActionAlpha = secondaryActionAlpha,
                stationaryOffsetPx = stationaryOffsetPx,
                onSelectSchool = openSchoolSelection,
                onWebLogin = openWebLogin
            )
            // 扫码方式没有提交按钮：二维码确认后由脚本自动完成登录。
            if (scriptLogin == null || scriptMethod?.kind != "qrcode") {
                LoginPrimaryAction(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp)
                        .height(54.dp)
                        .graphicsLayer { translationY = loginTranslationYPx },
                    loading = pageLoading,
                    canSubmit = if (scriptLogin != null && scriptMethod != null) {
                        scriptMethod.fields.none { field ->
                            field.required && scriptLogin.values[field.id].isNullOrBlank()
                        }
                    } else {
                        username.isNotBlank() && password.isNotBlank() &&
                            (!model.captchaRequired || (captcha.isNotBlank() && model.captchaImage != null))
                    },
                    onPassword = {
                        focusManager.clearFocus()
                        if (scriptLogin != null) {
                            scriptLogin.submit()
                        } else {
                            model.login(username, password, rememberPassword, captcha)
                        }
                    }
                )
            }
            // 脚本登录新增的两类模态：按需验证码挑战、短信/扫码确定性失败。
            scriptLogin?.let { ScriptLoginDialogs(it) }
        }
    }
    }
}

@Composable
private fun SchoolSelectionPrompt(
    modifier: Modifier = Modifier,
    loading: Boolean,
    onSelectSchool: () -> Unit
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 20.dp, bottom = 20.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            "选择学校以继续登录",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodyMedium
        )
        Spacer(Modifier.height(12.dp))
        Button(
            onClick = onSelectSchool,
            enabled = !loading,
            modifier = Modifier.fillMaxWidth().height(54.dp),
            shape = LoginPillShape,
            colors = loginPrimaryButtonColors()
        ) {
            Box(Modifier.fillMaxWidth()) {
                Icon(
                    Icons.Outlined.School,
                    contentDescription = null,
                    modifier = Modifier.align(Alignment.CenterStart)
                )
                Text(
                    "选择学校",
                    modifier = Modifier.align(Alignment.Center),
                    fontWeight = FontWeight.SemiBold
                )
            }
        }
    }
}

@Composable
private fun LoginSecondaryActions(
    modifier: Modifier = Modifier,
    selectedSchoolName: String,
    loading: Boolean,
    secondaryActionAlpha: Float,
    stationaryOffsetPx: Float,
    onSelectSchool: () -> Unit,
    onWebLogin: () -> Unit
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 20.dp, bottom = 20.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        OutlinedButton(
            onClick = onSelectSchool,
            enabled = !loading,
            modifier = Modifier
                .fillMaxWidth()
                .height(52.dp)
                .graphicsLayer {
                    alpha = secondaryActionAlpha
                    translationY = stationaryOffsetPx
                },
            shape = LoginPillShape,
            colors = ButtonDefaults.outlinedButtonColors(
                contentColor = MaterialTheme.colorScheme.onSurface,
                disabledContentColor = MaterialTheme.colorScheme.onSurfaceVariant
            )
        ) {
            Icon(Icons.Outlined.School, null)
            Spacer(Modifier.size(16.dp))
            Text(
                selectedSchoolName.ifBlank { "选择学校" },
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Icon(Icons.Outlined.ChevronRight, null)
        }
        Spacer(Modifier.height(54.dp))
        OutlinedButton(
            onClick = onWebLogin,
            enabled = !loading,
            modifier = Modifier
                .fillMaxWidth()
                .height(52.dp)
                .graphicsLayer {
                    alpha = secondaryActionAlpha
                    translationY = stationaryOffsetPx
                },
            shape = LoginPillShape,
            colors = ButtonDefaults.outlinedButtonColors(
                contentColor = MaterialTheme.colorScheme.onSurface,
                disabledContentColor = MaterialTheme.colorScheme.onSurfaceVariant
            )
        ) {
            Icon(Icons.Outlined.OpenInBrowser, null)
            Spacer(Modifier.size(8.dp))
            Text("用网页登录")
        }
    }
}

@Composable
private fun LoginPrimaryAction(
    modifier: Modifier = Modifier,
    loading: Boolean,
    canSubmit: Boolean,
    onPassword: () -> Unit
) {
    Button(
        onClick = onPassword,
        enabled = !loading && canSubmit,
        modifier = modifier,
        shape = LoginPillShape,
        colors = loginPrimaryButtonColors()
    ) {
        if (loading) {
            CircularProgressIndicator(
                Modifier.size(20.dp),
                strokeWidth = 2.dp,
                color = MaterialTheme.colorScheme.onPrimary
            )
        } else {
            Icon(Icons.Outlined.Lock, null)
            Spacer(Modifier.size(8.dp))
            Text("登录", fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun loginPrimaryButtonColors() = if (
    MaterialTheme.colorScheme.background.luminance() < 0.5f
) {
    ButtonDefaults.buttonColors(
        containerColor = MaterialTheme.colorScheme.primaryContainer,
        contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
        disabledContainerColor = MaterialTheme.colorScheme.surfaceVariant,
        disabledContentColor = MaterialTheme.colorScheme.onSurfaceVariant
    )
} else {
    ButtonDefaults.buttonColors(
        containerColor = MaterialTheme.colorScheme.primary,
        contentColor = MaterialTheme.colorScheme.onPrimary,
        disabledContainerColor = MaterialTheme.colorScheme.surfaceVariant,
        disabledContentColor = MaterialTheme.colorScheme.onSurfaceVariant
    )
}

@Composable
private fun LoginFormLabel(text: String) {
    Text(
        text = text,
        modifier = Modifier.padding(start = 8.dp, bottom = 6.dp),
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        fontWeight = FontWeight.SemiBold
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// 以下全部是 type=script 学校在原登录页上【新增】的控件：
//   1) 登录方式分段切换（密码/短信/扫码，仅多方式时出现）
//   2) schema 字段渲染（复用原 18/6 拼接输入框样式；短信验证码尾部的“获取验证码”
//      是唯一新增的字段尾部控件，图形验证码尾部图片沿用原有样式）
//   3) 扫码面板（替换输入框组，确认后脚本自动登录）
//   4) 按需验证码挑战弹窗 与 短信/扫码“登录失败”弹窗
// 原登录页的品牌行、布局、按钮、键盘抬升等均未改动。
// ─────────────────────────────────────────────────────────────────────────────

private enum class ScriptFieldPosition { FIRST, MIDDLE, LAST, SOLO }

@Composable
private fun ScriptLoginFormSection(
    script: ScriptLoginController,
    fieldColors: TextFieldColors,
    backdrop: Backdrop
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (script.phase == ScriptLoginController.Phase.LOADING) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = 28.dp),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically
            ) {
                CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
                Spacer(Modifier.size(12.dp))
                Text(
                    "正在准备登录…",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodyMedium
                )
            }
            return
        }
        script.initError?.let { message ->
            ScriptErrorSurface(message)
            return
        }
        val method = script.currentMethod() ?: return
        // 方式切换菜单必须由脚本在 describe() 显式声明 methodSwitch:true 才出现。
        if (script.methodSwitch && script.methods.size > 1) {
            ScriptMethodTabs(script)
        }
        // 方式切换时整块内容横向滑入滑出 + 淡入淡出（与 iOS methodSwitch 转场同向）。
        AnimatedContent(
            targetState = method.id,
            transitionSpec = {
                (fadeIn(tween(220)) +
                    slideInHorizontally(tween(280)) { it / 6 }) togetherWith
                    (fadeOut(tween(160)) +
                        slideOutHorizontally(tween(200)) { -it / 6 })
            },
            label = "scriptMethodBody"
        ) { currentMethodId ->
            val current = script.methods.firstOrNull { it.id == currentMethodId } ?: method
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (current.kind == "qrcode") {
                    ScriptQrPanel(script)
                } else {
                    LoginFormLabel(current.label)
                    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        current.fields.forEachIndexed { index, field ->
                            val position = when {
                                current.fields.size == 1 -> ScriptFieldPosition.SOLO
                                index == 0 -> ScriptFieldPosition.FIRST
                                index == current.fields.lastIndex -> ScriptFieldPosition.LAST
                                else -> ScriptFieldPosition.MIDDLE
                            }
                            ScriptField(script, field, position, fieldColors)
                        }
                    }
                    current.checkboxes.forEach { checkbox ->
                        ScriptCheckboxCard(
                            label = checkbox.label,
                            checked = script.checkboxes.getOrDefault(checkbox.id, checkbox.defaultChecked),
                            onCheckedChange = { script.toggleCheckbox(checkbox.id) },
                            backdrop = backdrop
                        )
                    }
                    // 提示条随状态展开/淡出，不做硬切。
                    AnimatedVisibility(
                        visible = script.error != null,
                        enter = fadeIn() + expandVertically(),
                        exit = fadeOut() + shrinkVertically()
                    ) {
                        script.error?.let { ScriptErrorSurface(it) }
                    }
                    AnimatedVisibility(
                        visible = script.status != null,
                        enter = fadeIn() + expandVertically(),
                        exit = fadeOut() + shrinkVertically()
                    ) {
                        script.status?.let { ScriptStatusSurface(it) }
                    }
                }
            }
        }
    }
}

/**
 * Material Expressive 风格的方式切换栏：
 * 未选中项为圆角矩形（约 30% 圆角），选中项在 280ms 内过渡为 50% 胶囊，
 * 容器色、文字色同步过渡，配合表单区的滑动转场构成完整切换反馈。
 */
@Composable
private fun ScriptMethodTabs(script: ScriptLoginController) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        script.methods.forEach { method ->
            val selected = method.id == script.methodId
            val cornerPercent by animateIntAsState(
                targetValue = if (selected) 50 else 30,
                animationSpec = tween(durationMillis = 280, easing = FastOutSlowInEasing),
                label = "methodTabShape"
            )
            val containerColor by animateColorAsState(
                targetValue = if (selected) {
                    MaterialTheme.colorScheme.primary
                } else {
                    MaterialTheme.colorScheme.surfaceVariant
                },
                animationSpec = tween(280, easing = FastOutSlowInEasing),
                label = "methodTabContainer"
            )
            val contentColor by animateColorAsState(
                targetValue = if (selected) {
                    MaterialTheme.colorScheme.onPrimary
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                },
                animationSpec = tween(280, easing = FastOutSlowInEasing),
                label = "methodTabContent"
            )
            Box(
                modifier = Modifier
                    .weight(1f)
                    .height(44.dp)
                    .clip(RoundedCornerShape(percent = cornerPercent))
                    .background(containerColor)
                    .clickable(enabled = !script.busy) {
                        script.selectMethod(method)
                    },
                contentAlignment = Alignment.Center
            ) {
                Text(
                    method.label,
                    color = contentColor,
                    fontSize = 13.sp,
                    maxLines = 1,
                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium
                )
            }
        }
    }
}

@Composable
private fun ScriptField(
    script: ScriptLoginController,
    field: LoginScriptRuntime.Field,
    position: ScriptFieldPosition,
    fieldColors: TextFieldColors
) {
    val value = script.values[field.id].orEmpty()
    val shape = when (position) {
        ScriptFieldPosition.SOLO -> RoundedCornerShape(18.dp)
        ScriptFieldPosition.FIRST -> RoundedCornerShape(
            topStart = 18.dp, topEnd = 18.dp, bottomStart = 6.dp, bottomEnd = 6.dp
        )
        ScriptFieldPosition.LAST -> RoundedCornerShape(
            topStart = 6.dp, topEnd = 6.dp, bottomStart = 18.dp, bottomEnd = 18.dp
        )
        ScriptFieldPosition.MIDDLE -> RoundedCornerShape(6.dp)
    }
    val isLast = position == ScriptFieldPosition.LAST || position == ScriptFieldPosition.SOLO
    var reveal by remember(field.id, script.methodId) { mutableStateOf(false) }
    TextField(
        value = value,
        onValueChange = { script.setValue(field.id, it) },
        label = { Text(field.label) },
        placeholder = field.placeholder.takeIf(String::isNotBlank)?.let { placeholderText ->
            @Composable { Text(placeholderText) }
        },
        leadingIcon = {
            Icon(
                when (field.type) {
                    "password" -> Icons.Outlined.Key
                    "tel" -> Icons.Outlined.Phone
                    "smsCode" -> Icons.Outlined.Sms
                    "captcha" -> Icons.Outlined.Lock
                    else -> Icons.Outlined.AccountCircle
                },
                null
            )
        },
        trailingIcon = when (field.type) {
            "password" -> {
                {
                    IconButton(onClick = { reveal = !reveal }) {
                        Icon(
                            if (reveal) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility,
                            if (reveal) "隐藏密码" else "显示密码"
                        )
                    }
                }
            }
            "captcha" -> {
                { ScriptCaptchaImage(script, field) }
            }
            "smsCode" -> {
                { ScriptSmsSendButton(script, field) }
            }
            else -> null
        },
        singleLine = true,
        visualTransformation = if (field.type == "password" && !reveal) {
            PasswordVisualTransformation()
        } else {
            VisualTransformation.None
        },
        keyboardOptions = KeyboardOptions(
            keyboardType = when (field.type) {
                "password" -> KeyboardType.Password
                "tel" -> KeyboardType.Phone
                "smsCode" -> KeyboardType.Number
                else -> KeyboardType.Text
            },
            imeAction = if (isLast) ImeAction.Done else ImeAction.Next
        ),
        keyboardActions = KeyboardActions(
            onDone = { if (isLast) script.submit() }
        ),
        shape = shape,
        colors = fieldColors,
        modifier = Modifier.fillMaxWidth().height(LoginTextFieldHeight)
    )
}

// 图形验证码尾部：与原登录页验证码框同款（112x48 圆角可点刷新）。
@Composable
private fun ScriptCaptchaImage(script: ScriptLoginController, field: LoginScriptRuntime.Field) {
    Box(
        modifier = Modifier
            .padding(end = 8.dp)
            .size(width = 112.dp, height = 48.dp)
            .clip(RoundedCornerShape(8.dp))
            .clickable(enabled = !script.busy) { script.refreshCaptcha(field) },
        contentAlignment = Alignment.Center
    ) {
        val bytes = script.captchaImages[field.id]
        val bitmap = remember(bytes) {
            bytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
        }
        when {
            bytes != null && bitmap != null -> Image(
                bitmap = bitmap.asImageBitmap(),
                contentDescription = "验证码图片，点按刷新",
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize()
            )
            script.busy -> CircularProgressIndicator(
                modifier = Modifier.size(20.dp),
                strokeWidth = 2.dp
            )
            else -> Icon(Icons.Outlined.Refresh, "刷新验证码")
        }
    }
}

// 唯一新增的字段尾部控件：短信验证码“获取/倒计时”按钮。
@Composable
private fun ScriptSmsSendButton(script: ScriptLoginController, field: LoginScriptRuntime.Field) {
    val cooldown = script.smsCooldown
    val enabled = cooldown == 0 && !script.busy
    Box(
        modifier = Modifier
            .padding(end = 8.dp)
            .size(width = 104.dp, height = 44.dp)
            .clip(RoundedCornerShape(8.dp))
            .clickable(enabled = enabled) { script.sendSms(field) },
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = if (cooldown > 0) "${cooldown}s 后重发" else "获取验证码",
            color = if (enabled) {
                MaterialTheme.colorScheme.primary
            } else {
                MaterialTheme.colorScheme.onSurfaceVariant
            },
            style = MaterialTheme.typography.labelLarge,
            maxLines = 1
        )
    }
}

@Composable
private fun ScriptCheckboxCard(
    label: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    backdrop: Backdrop
) {
    Card(
        modifier = Modifier.fillMaxWidth().clip(LoginPillShape),
        shape = LoginPillShape,
        colors = CardDefaults.cardColors(containerColor = PortalCardBackground),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .weight(1f)
                    .height(48.dp)
                    .clickable { onCheckedChange(!checked) },
                contentAlignment = Alignment.CenterStart
            ) {
                Text(label, fontWeight = FontWeight.Medium)
            }
            PortalGlassSwitch(
                checked = checked,
                onCheckedChange = onCheckedChange,
                backdrop = backdrop,
                label = label
            )
        }
    }
}

@Composable
private fun ScriptQrPanel(script: ScriptLoginController) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(top = 4.dp, bottom = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Box(
            modifier = Modifier
                .size(232.dp)
                .clip(RoundedCornerShape(18.dp))
                .background(Color.White)
                .padding(12.dp),
            contentAlignment = Alignment.Center
        ) {
            val image = script.qrImage
            when {
                image != null -> Image(
                    bitmap = image.asImageBitmap(),
                    contentDescription = "登录二维码",
                    contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxSize()
                )
                else -> CircularProgressIndicator(Modifier.size(32.dp), strokeWidth = 2.dp)
            }
        }
        val message = script.qrMessage.ifBlank {
            when (script.qrState) {
                "scanned" -> "已扫描，请在手机上确认"
                "expired" -> "二维码已失效，正在重新生成…"
                else -> "请使用学校 App 扫码登录"
            }
        }
        Text(
            message,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodyMedium
        )
        AnimatedVisibility(
            visible = script.error != null,
            enter = fadeIn() + expandVertically(),
            exit = fadeOut() + shrinkVertically()
        ) {
            script.error?.let { ScriptErrorSurface(it) }
        }
        AnimatedVisibility(
            visible = script.status != null,
            enter = fadeIn() + expandVertically(),
            exit = fadeOut() + shrinkVertically()
        ) {
            script.status?.let { ScriptStatusSurface(it) }
        }
    }
}

// 输入框下方的错误提示：不加底色，仅错误色小字。
@Composable
private fun ScriptErrorSurface(message: String) {
    Text(
        message,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 4.dp, vertical = 2.dp),
        color = MaterialTheme.colorScheme.error,
        style = MaterialTheme.typography.bodyMedium
    )
}

// 输入框下方的状态提示（验证码加载中、重试中等）：不加底色，仅转圈 + 次级文字。
@Composable
private fun ScriptStatusSurface(message: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 4.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
        Text(
            message,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodyMedium
        )
    }
}

@Composable
private fun ScriptLoginDialogs(script: ScriptLoginController) {
    script.captchaChallenge?.let {
        AlertDialog(
            onDismissRequest = { script.dismissCaptchaDialog() },
            title = { Text("请输入验证码") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("学校要求本次登录补输图形验证码。", style = MaterialTheme.typography.bodyMedium)
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(64.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .background(Color.White)
                            .clickable { script.refreshDialogCaptcha() },
                        contentAlignment = Alignment.Center
                    ) {
                        val bytes = script.captchaDialogImage
                        val bitmap = remember(bytes) {
                            bytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
                        }
                        when {
                            bytes != null && bitmap != null -> Image(
                                bitmap = bitmap.asImageBitmap(),
                                contentDescription = "验证码图片，点按刷新",
                                contentScale = ContentScale.Fit,
                                modifier = Modifier.fillMaxSize().padding(4.dp)
                            )
                            else -> Row(
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                                Text("点按刷新", style = MaterialTheme.typography.bodyMedium)
                            }
                        }
                    }
                    OutlinedTextField(
                        value = script.captchaDialogInput,
                        onValueChange = script::typeCaptchaInput,
                        singleLine = true,
                        label = { Text("验证码") },
                        keyboardOptions = KeyboardOptions(
                            keyboardType = KeyboardType.Text,
                            imeAction = ImeAction.Done
                        ),
                        keyboardActions = KeyboardActions(
                            onDone = { script.confirmCaptchaDialog() }
                        ),
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = { script.confirmCaptchaDialog() },
                    enabled = script.captchaDialogInput.isNotBlank()
                ) { Text("确定") }
            },
            dismissButton = {
                TextButton(onClick = { script.dismissCaptchaDialog() }) { Text("取消") }
            }
        )
    }
    script.failureDialog?.let { message ->
        AlertDialog(
            onDismissRequest = { script.dismissFailure() },
            title = { Text("登录失败") },
            text = { Text(message, style = MaterialTheme.typography.bodyMedium) },
            confirmButton = {
                TextButton(onClick = { script.retryAfterFailure() }) { Text("重试") }
            },
            dismissButton = {
                TextButton(onClick = { script.dismissFailure() }) { Text("取消") }
            }
        )
    }
}
