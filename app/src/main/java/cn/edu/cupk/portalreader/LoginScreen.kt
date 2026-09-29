package cn.edu.cupk.portalreader

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
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
import androidx.compose.material.icons.outlined.School
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
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
    var rememberPassword by remember { mutableStateOf(model.rememberedCredential != null) }
    var revealPassword by remember { mutableStateOf(false) }
    var restingContentHeightPx by remember { mutableStateOf(0) }
    val passwordFocusRequester = remember { FocusRequester() }
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
        rememberPassword = model.rememberedCredential != null
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
                    Column(
                        modifier = Modifier.fillMaxWidth().height(172.dp).clipToBounds(),
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        Image(
                            painter = painterResource(R.drawable.ic_launcher_foreground),
                            contentDescription = "掌上教务标识",
                            modifier = Modifier.size(88.dp)
                        )
                        Spacer(Modifier.height(12.dp))
                        Text(
                            "掌上教务",
                            style = MaterialTheme.typography.displaySmall,
                            color = MaterialTheme.colorScheme.onBackground,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }
            }

            if (model.hasSelectedSchool) {
                item(key = "password-form") {
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
                                        imeAction = ImeAction.Done
                                    ),
                                    keyboardActions = KeyboardActions(onDone = {
                                        if (username.isNotBlank() && password.isNotBlank()) {
                                            focusManager.clearFocus()
                                            model.login(username, password, rememberPassword)
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
                                        .focusRequester(passwordFocusRequester)
                                )
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

                            model.error?.let { message ->
                                Surface(
                                    modifier = Modifier.fillMaxWidth(),
                                    shape = RoundedCornerShape(14.dp),
                                    color = MaterialTheme.colorScheme.errorContainer
                                ) {
                                    Text(
                                        message,
                                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 11.dp),
                                        color = MaterialTheme.colorScheme.onErrorContainer,
                                        style = MaterialTheme.typography.bodyMedium
                                    )
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
            LoginSecondaryActions(
                modifier = Modifier.align(Alignment.BottomCenter),
                selectedSchoolName = selectedSchoolName,
                loading = model.loading,
                secondaryActionAlpha = secondaryActionAlpha,
                stationaryOffsetPx = stationaryOffsetPx,
                onSelectSchool = openSchoolSelection,
                onWebLogin = openWebLogin
            )
            LoginPrimaryAction(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .padding(horizontal = 20.dp)
                    .height(54.dp)
                    .graphicsLayer { translationY = loginTranslationYPx },
                loading = model.loading,
                canSubmit = username.isNotBlank() && password.isNotBlank(),
                onPassword = {
                    focusManager.clearFocus()
                    model.login(username, password, rememberPassword)
                }
            )
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
