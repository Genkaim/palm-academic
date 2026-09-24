package cn.edu.cupk.portalreader

import android.app.Application
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

sealed interface PortalSessionState {
    data object NoSession : PortalSessionState
    data object Checking : PortalSessionState
    data object Ready : PortalSessionState
    data object Expired : PortalSessionState
    data class Unavailable(val message: String) : PortalSessionState
}

private enum class SessionStatusStage { HIDDEN, CHECKING, UNAVAILABLE }

/**
 * Owns the foreground session check for the whole app process. Activities can be opened while
 * the check is still running and will all observe the same progress instead of starting their
 * own competing login/session requests.
 */
object PortalSessionCoordinator {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val _state = MutableStateFlow<PortalSessionState>(PortalSessionState.NoSession)
    val state: StateFlow<PortalSessionState> = _state.asStateFlow()

    private var validationJob: Job? = null

    fun initialize(application: Application) {
        if (PortalHttp.hasSessionCookie()) validate(application)
        else _state.value = PortalSessionState.NoSession
    }

    fun validate(application: Application, force: Boolean = false) {
        if (!PortalHttp.hasSessionCookie()) {
            _state.value = PortalSessionState.NoSession
            return
        }
        if (!force && (validationJob?.isActive == true || _state.value == PortalSessionState.Ready)) return

        validationJob?.cancel()
        _state.value = PortalSessionState.Checking
        validationJob = scope.launch {
            when (AuthRepository().validateSession()) {
                SessionValidation.VALID -> _state.value = PortalSessionState.Ready
                SessionValidation.EXPIRED -> {
                    PortalHttp.clearSession()
                    _state.value = PortalSessionState.Expired
                }
                SessionValidation.UNAVAILABLE -> {
                    _state.value = PortalSessionState.Unavailable("网络较慢，或当前网络无法访问教务系统")
                }
            }
        }
    }

    fun markAuthenticated() {
        validationJob?.cancel()
        _state.value = PortalSessionState.Ready
    }

    fun clear() {
        validationJob?.cancel()
        _state.value = PortalSessionState.NoSession
    }
}

@Composable
fun PortalSessionStatus(
    state: PortalSessionState,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier
) {
    val stage = when (state) {
        PortalSessionState.Checking -> SessionStatusStage.CHECKING
        is PortalSessionState.Unavailable -> SessionStatusStage.UNAVAILABLE
        else -> SessionStatusStage.HIDDEN
    }
    AnimatedContent(
        targetState = stage,
        modifier = modifier,
        contentAlignment = Alignment.CenterEnd,
        transitionSpec = {
            (fadeIn() + expandHorizontally(expandFrom = Alignment.End)) togetherWith
                (fadeOut() + shrinkHorizontally(shrinkTowards = Alignment.End))
        },
        label = "session-status"
    ) { target ->
        when (target) {
            SessionStatusStage.HIDDEN -> Spacer(Modifier.size(0.dp))
            SessionStatusStage.CHECKING, SessionStatusStage.UNAVAILABLE -> Row(
                modifier = Modifier.then(
                    if (target == SessionStatusStage.UNAVAILABLE) Modifier.clickable(onClick = onRetry)
                    else Modifier
                ),
                horizontalArrangement = Arrangement.spacedBy(7.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                if (target == SessionStatusStage.CHECKING) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                }
                Text(
                    text = if (target == SessionStatusStage.CHECKING) "尝试登录…" else "验证失败，点击重试",
                    color = if (target == SessionStatusStage.UNAVAILABLE) MaterialTheme.colorScheme.error
                    else MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.Medium
                )
            }
        }
    }
}
