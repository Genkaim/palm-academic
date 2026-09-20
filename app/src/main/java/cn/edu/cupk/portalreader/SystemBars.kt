package cn.edu.cupk.portalreader

import android.graphics.Color
import androidx.activity.ComponentActivity
import androidx.core.view.WindowCompat

@Suppress("DEPRECATION")
fun ComponentActivity.useContinuousSystemBars(
    lightStatusIcons: Boolean = !PortalThemePreferences.isDark(this)
) {
    WindowCompat.setDecorFitsSystemWindows(window, false)
    window.statusBarColor = Color.TRANSPARENT
    window.navigationBarColor = Color.TRANSPARENT
    WindowCompat.getInsetsController(window, window.decorView).apply {
        isAppearanceLightStatusBars = lightStatusIcons
        isAppearanceLightNavigationBars = lightStatusIcons
    }
}
