package cn.edu.cupk.portalreader

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Bundle
import android.webkit.WebSettings
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.app.AppCompatDelegate
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature

enum class PortalThemeMode(val storedValue: String, val displayName: String) {
    SYSTEM("system", "跟随系统"),
    LIGHT("light", "浅色"),
    DARK("dark", "深色");

    companion object {
        fun fromStoredValue(value: String?): PortalThemeMode =
            entries.firstOrNull { it.storedValue == value } ?: SYSTEM
    }
}

object PortalThemePreferences {
    private const val PREFS = "appearance"
    private const val KEY_THEME_MODE = "theme_mode"
    private const val KEY_GLASS_ENABLED = "glass_enabled"
    private var initialized = false

    var mode by mutableStateOf(PortalThemeMode.SYSTEM)
        private set

    var glassEnabled by mutableStateOf(true)
        private set

    fun initialize(context: Context) {
        if (initialized) return
        mode = read(context)
        glassEnabled = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_GLASS_ENABLED, true)
        initialized = true
    }

    fun set(context: Context, value: PortalThemeMode) {
        initialize(context.applicationContext)
        if (mode == value) return
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_THEME_MODE, value.storedValue)
            .apply()
        mode = value
    }

    fun setGlassEnabled(context: Context, enabled: Boolean) {
        initialize(context.applicationContext)
        glassEnabled = enabled
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_GLASS_ENABLED, enabled)
            .apply()
    }

    fun isDark(context: Context): Boolean = when (mode) {
        PortalThemeMode.DARK -> true
        PortalThemeMode.LIGHT -> false
        PortalThemeMode.SYSTEM -> context.resources.configuration.uiMode and
            Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    }

    private fun read(context: Context): PortalThemeMode = PortalThemeMode.fromStoredValue(
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_THEME_MODE, PortalThemeMode.SYSTEM.storedValue)
    )

}

open class PortalActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        PortalThemePreferences.initialize(applicationContext)
        delegate.localNightMode = when (PortalThemePreferences.mode) {
            PortalThemeMode.SYSTEM -> AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM
            PortalThemeMode.LIGHT -> AppCompatDelegate.MODE_NIGHT_NO
            PortalThemeMode.DARK -> AppCompatDelegate.MODE_NIGHT_YES
        }
        super.onCreate(savedInstanceState)
    }

    @Suppress("DEPRECATION")
    fun startPortalActivity(intent: Intent) {
        startActivity(intent)
        overridePendingTransition(R.anim.fade_in, R.anim.activity_stay)
    }

    @Suppress("DEPRECATION")
    fun finishPortalActivity() {
        finish()
        overridePendingTransition(R.anim.activity_stay, R.anim.fade_out)
    }
}

private val LightPortalColors = lightColorScheme(
    primary = Color(0xFF3A3A3C),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFE5E5EA),
    onPrimaryContainer = Color(0xFF1C1C1E),
    secondary = Color(0xFF3A3A3C),
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFE5E5EA),
    onSecondaryContainer = Color(0xFF1C1C1E),
    tertiary = Color(0xFF3A3A3C),
    onTertiary = Color.White,
    background = Color(0xFFF2F2F7),
    onBackground = Color(0xFF1C1C1E),
    surface = Color(0xFFFFFFFF),
    onSurface = Color(0xFF1C1C1E),
    surfaceVariant = Color(0xFFE5E5EA),
    onSurfaceVariant = Color(0xFF636366),
    outline = Color(0xFF8E8E93),
    error = Color(0xFFFF3B30),
    errorContainer = Color(0xFFFFE5E3),
    onErrorContainer = Color(0xFF8A120B)
)

private val DarkPortalColors = darkColorScheme(
    primary = Color(0xFF48484A),
    onPrimary = Color.White,
    primaryContainer = Color(0xFF2C2C2E),
    onPrimaryContainer = Color(0xFFF2F2F7),
    secondary = Color(0xFF48484A),
    onSecondary = Color.White,
    secondaryContainer = Color(0xFF2C2C2E),
    onSecondaryContainer = Color(0xFFF2F2F7),
    tertiary = Color(0xFF48484A),
    onTertiary = Color.White,
    background = Color(0xFF000000),
    onBackground = Color(0xFFF2F2F7),
    surface = Color(0xFF1C1C1E),
    onSurface = Color(0xFFF2F2F7),
    surfaceVariant = Color(0xFF2C2C2E),
    onSurfaceVariant = Color(0xFFAEAEB2),
    outline = Color(0xFF8E8E93),
    error = Color(0xFFFF453A),
    onError = Color(0xFF690005),
    errorContainer = Color(0xFF93000A),
    onErrorContainer = Color(0xFFFFDAD6)
)

val PortalBlue: Color
    @Composable get() = MaterialTheme.colorScheme.onSurface
val PortalBlueDeep: Color
    @Composable get() = MaterialTheme.colorScheme.onSurface
val PortalBlueSoft: Color
    @Composable get() = MaterialTheme.colorScheme.surfaceVariant
val PortalPageBackground: Color
    @Composable get() = MaterialTheme.colorScheme.background
val PortalCardBackground: Color
    @Composable get() = MaterialTheme.colorScheme.surface
val PortalControlBackground: Color
    @Composable get() = MaterialTheme.colorScheme.secondaryContainer
val PortalInk: Color
    @Composable get() = MaterialTheme.colorScheme.onSurface
val PortalSuccess: Color
    @Composable get() = MaterialTheme.colorScheme.onSurfaceVariant

/** Keeps every app-owned top control visually connected to the page behind it. */
@Composable
fun portalTopGradient(): Brush {
    val background = MaterialTheme.colorScheme.background
    return Brush.verticalGradient(
        colorStops = arrayOf(
            0f to background,
            0.34f to background,
            1f to background.copy(alpha = 0f)
        )
    )
}

val PortalTopFadeDepth = 40.dp

/** Adds a transparent lower edge; screens deliberately draw their content beneath this area. */
@Composable
fun Modifier.portalTopGradientBackground(fadeDepth: Dp = PortalTopFadeDepth): Modifier {
    val background = MaterialTheme.colorScheme.background
    return this
        .drawBehind {
            val fadePixels = (fadeDepth + 28.dp).toPx().coerceAtMost(size.height)
            val transparentTail = 28.dp.toPx().coerceAtMost(size.height)
            val fadeEndPixels = (size.height - transparentTail).coerceAtLeast(0f)
            val fadeStartPixels = (fadeEndPixels - fadePixels).coerceAtLeast(0f)
            val fadeStart = if (size.height > 0f) {
                (fadeStartPixels / size.height).coerceIn(0f, 1f)
            } else {
                1f
            }
            val fadeEnd = if (size.height > 0f) {
                (fadeEndPixels / size.height).coerceIn(fadeStart, 1f)
            } else {
                1f
            }
            drawRect(
                brush = Brush.verticalGradient(
                    colorStops = arrayOf(
                        0f to background,
                        fadeStart to background,
                        fadeEnd to background.copy(alpha = 0f),
                        1f to background.copy(alpha = 0f)
                    )
                )
            )
        }
        .padding(bottom = fadeDepth)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PortalGradientTopAppBar(
    title: @Composable () -> Unit,
    modifier: Modifier = Modifier,
    navigationIcon: @Composable () -> Unit = {},
    actions: @Composable RowScope.() -> Unit = {}
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .portalTopGradientBackground()
    ) {
        TopAppBar(
            title = title,
            navigationIcon = navigationIcon,
            actions = actions,
            colors = TopAppBarDefaults.topAppBarColors(
                containerColor = Color.Transparent,
                scrolledContainerColor = Color.Transparent
            )
        )
    }
}

@Composable
fun PortalTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val selectedMode = PortalThemePreferences.mode
    val darkTheme = when (selectedMode) {
        PortalThemeMode.SYSTEM -> isSystemInDarkTheme()
        PortalThemeMode.LIGHT -> false
        PortalThemeMode.DARK -> true
    }
    SideEffect {
        (context as? PortalActivity)?.useContinuousSystemBars(lightStatusIcons = !darkTheme)
    }
    MaterialTheme(
        colorScheme = if (darkTheme) DarkPortalColors else LightPortalColors,
        content = content
    )
}

data class PortalViewColors(
    val pageBackground: Int,
    val webBackground: Int,
    val text: Int,
    val secondaryText: Int,
    val accent: Int,
    val errorText: Int,
    val errorBackground: Int
)

fun portalViewColors(context: Context): PortalViewColors = if (PortalThemePreferences.isDark(context)) {
    PortalViewColors(
        pageBackground = android.graphics.Color.rgb(0, 0, 0),
        webBackground = android.graphics.Color.rgb(28, 28, 30),
        text = android.graphics.Color.rgb(242, 242, 247),
        secondaryText = android.graphics.Color.rgb(174, 174, 178),
        accent = android.graphics.Color.rgb(72, 72, 74),
        errorText = android.graphics.Color.rgb(255, 218, 214),
        errorBackground = android.graphics.Color.rgb(92, 25, 29)
    )
} else {
    PortalViewColors(
        pageBackground = android.graphics.Color.rgb(242, 242, 247),
        webBackground = android.graphics.Color.WHITE,
        text = android.graphics.Color.rgb(28, 28, 30),
        secondaryText = android.graphics.Color.rgb(99, 99, 102),
        accent = android.graphics.Color.rgb(58, 58, 60),
        errorText = android.graphics.Color.rgb(150, 30, 30),
        errorBackground = android.graphics.Color.rgb(255, 235, 235)
    )
}

@Suppress("DEPRECATION")
fun configurePortalWebDarkening(settings: WebSettings, dark: Boolean) {
    if (WebViewFeature.isFeatureSupported(WebViewFeature.ALGORITHMIC_DARKENING)) {
        WebSettingsCompat.setAlgorithmicDarkeningAllowed(settings, dark)
    } else if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
        settings.forceDark = if (dark) WebSettings.FORCE_DARK_ON else WebSettings.FORCE_DARK_OFF
    }
}
