package dev.vmd1.gossip.ui.theme

import android.content.Context
import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** Apple's system blue — see `docs/design-system.md` for why this is the shared accent
 *  reference point across both platforms (it's also SwiftUI's default macOS accent). */
val ConnectBlue = Color(0xFF0A84FF)

/** The app's accent, picked under Settings → Theme. [SYSTEM] follows the wallpaper (Material You, Android 12+). */
enum class Accent(val label: String, val color: Color) {
    SYSTEM("System", ConnectBlue),
    ORANGE("Orange", Color(0xFFFF6B35)),
    BLUE("Blue", ConnectBlue),
    PURPLE("Purple", Color(0xFF8E5CF6)),
    GREEN("Green", Color(0xFF10A37F));
}

/** The chosen [Accent], kept on this device only. */
class ThemeSettings private constructor(context: Context) {
    private val prefs = context.getSharedPreferences("theme", Context.MODE_PRIVATE)
    private val _accent = MutableStateFlow(
        Accent.entries.firstOrNull { it.name == prefs.getString("accent", null) } ?: Accent.SYSTEM
    )
    val accent: StateFlow<Accent> = _accent

    fun setAccent(accent: Accent) {
        prefs.edit().putString("accent", accent.name).apply()
        _accent.value = accent
    }

    companion object {
        @Volatile private var instance: ThemeSettings? = null
        fun getInstance(context: Context): ThemeSettings = instance ?: synchronized(this) {
            instance ?: ThemeSettings(context.applicationContext).also { instance = it }
        }
    }
}

/** Wraps a screen in a Material3 [MaterialTheme] in the chosen [Accent]: the wallpaper's colours for [Accent.SYSTEM]
 *  where Android has them, else a scheme seeded from the accent. Follows the device's light/dark setting. */
@Composable
fun ConnectTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val accent by remember { ThemeSettings.getInstance(context) }.accent.collectAsState()
    val dark = isSystemInDarkTheme()
    val scheme = when {
        accent == Accent.SYSTEM && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
            if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme(primary = accent.color)
        else -> lightColorScheme(primary = accent.color)
    }
    MaterialTheme(colorScheme = scheme, content = content)
}
