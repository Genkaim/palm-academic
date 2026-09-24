package cn.edu.cupk.portalreader

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import com.kyant.backdrop.Backdrop
import com.kyant.backdrop.catalog.components.LiquidToggle

/** App-facing wrapper around AndroidLiquidGlass' elastic, draggable toggle. */
@Composable
fun PortalGlassSwitch(
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    backdrop: Backdrop,
    modifier: Modifier = Modifier,
    glassEnabled: Boolean = PortalThemePreferences.glassEnabled,
    label: String = "开关"
) {
    val semanticsModifier = modifier.semantics {
        contentDescription = label
        stateDescription = if (checked) "已开启" else "已关闭"
    }
    LiquidToggle(
        selected = { checked },
        onSelect = onCheckedChange,
        backdrop = backdrop,
        glassEnabled = glassEnabled,
        modifier = semanticsModifier
    )
}
