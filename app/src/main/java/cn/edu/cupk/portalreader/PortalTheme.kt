package cn.edu.cupk.portalreader

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Bundle
import android.webkit.WebSettings
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.app.AppCompatDelegate
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
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
    private var initialized = false

    var mode by mutableStateOf(PortalThemeMode.SYSTEM)
        private set

    fun initialize(context: Context) {
        if (initialized) return
        mode = read(context)
        initialized = true
        apply(mode)
    }

    fun set(context: Context, value: PortalThemeMode) {
        initialize(context.applicationContext)
        if (mode == value) return
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_THEME_MODE, value.storedValue)
            .apply()
        mode = value
        apply(value)
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

    private fun apply(value: PortalThemeMode) {
        AppCompatDelegate.setDefaultNightMode(
            when (value) {
                PortalThemeMode.SYSTEM -> AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM
                PortalThemeMode.LIGHT -> AppCompatDelegate.MODE_NIGHT_NO
                PortalThemeMode.DARK -> AppCompatDelegate.MODE_NIGHT_YES
            }
        )
    }
}

open class PortalActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        PortalThemePreferences.initialize(applicationContext)
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
    primary = Color(0xFF315DA8),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFF0F4FA),
    onPrimaryContainer = Color(0xFF153C78),
    secondary = Color(0xFF52627A),
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFE9EFF8),
    onSecondaryContainer = Color(0xFF1B2B3F),
    tertiary = Color(0xFF187A62),
    onTertiary = Color.White,
    background = Color(0xFFF8F9FF),
    onBackground = Color(0xFF18212F),
    surface = Color(0xFFFCFCFE),
    onSurface = Color(0xFF18212F),
    surfaceVariant = Color(0xFFF1F3F8),
    onSurfaceVariant = Color(0xFF515866),
    outline = Color(0xFF737987),
    errorContainer = Color(0xFFFFEDEA),
    onErrorContainer = Color(0xFF410002)
)

private val DarkPortalColors = darkColorScheme(
    primary = Color(0xFFA9C7FF),
    onPrimary = Color(0xFF0B305D),
    primaryContainer = Color(0xFF203B63),
    onPrimaryContainer = Color(0xFFD6E4FF),
    secondary = Color(0xFFB8C7DD),
    onSecondary = Color(0xFF243247),
    secondaryContainer = Color(0xFF2B3A4E),
    onSecondaryContainer = Color(0xFFD7E3F8),
    tertiary = Color(0xFF63D3B2),
    onTertiary = Color(0xFF00382C),
    background = Color(0xFF101318),
    onBackground = Color(0xFFE3E7EF),
    surface = Color(0xFF191C22),
    onSurface = Color(0xFFE3E7EF),
    surfaceVariant = Color(0xFF262A32),
    onSurfaceVariant = Color(0xFFC2C6CF),
    outline = Color(0xFF8D929C),
    error = Color(0xFFFFB4AB),
    onError = Color(0xFF690005),
    errorContainer = Color(0xFF93000A),
    onErrorContainer = Color(0xFFFFDAD6)
)

val PortalBlue: Color
    @Composable get() = MaterialTheme.colorScheme.primary
val PortalBlueDeep: Color
    @Composable get() = MaterialTheme.colorScheme.onPrimaryContainer
val PortalBlueSoft: Color
    @Composable get() = MaterialTheme.colorScheme.primaryContainer
val PortalPageBackground: Color
    @Composable get() = MaterialTheme.colorScheme.background
val PortalCardBackground: Color
    @Composable get() = MaterialTheme.colorScheme.surface
val PortalControlBackground: Color
    @Composable get() = MaterialTheme.colorScheme.secondaryContainer
val PortalInk: Color
    @Composable get() = MaterialTheme.colorScheme.onSurface
val PortalSuccess: Color
    @Composable get() = MaterialTheme.colorScheme.tertiary

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
        pageBackground = android.graphics.Color.rgb(16, 19, 24),
        webBackground = android.graphics.Color.rgb(25, 28, 34),
        text = android.graphics.Color.rgb(227, 231, 239),
        secondaryText = android.graphics.Color.rgb(194, 198, 207),
        accent = android.graphics.Color.rgb(169, 199, 255),
        errorText = android.graphics.Color.rgb(255, 218, 214),
        errorBackground = android.graphics.Color.rgb(92, 25, 29)
    )
} else {
    PortalViewColors(
        pageBackground = android.graphics.Color.rgb(248, 249, 255),
        webBackground = android.graphics.Color.WHITE,
        text = android.graphics.Color.rgb(24, 33, 47),
        secondaryText = android.graphics.Color.rgb(81, 88, 102),
        accent = android.graphics.Color.rgb(49, 93, 168),
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
