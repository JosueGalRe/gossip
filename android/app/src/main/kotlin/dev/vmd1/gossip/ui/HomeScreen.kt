package dev.vmd1.gossip.ui

import android.app.Activity
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BatteryChargingFull
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Cast
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.DoNotDisturbOn
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Mouse
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.automirrored.filled.ScreenShare
import androidx.compose.material.icons.filled.Sms
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.WifiTethering
import androidx.compose.material.icons.filled.WifiTetheringOff
import androidx.compose.material3.BottomSheetScaffold
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.rememberBottomSheetScaffoldState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PointMode
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat
import dev.vmd1.gossip.BuildConfig
import dev.vmd1.gossip.crypto.TrustedDevice
import dev.vmd1.gossip.features.battery.BatteryState
import dev.vmd1.gossip.features.hotspot.HotspotState
import dev.vmd1.gossip.features.messages.MessagesSettings
import dev.vmd1.gossip.features.notifications.NotificationForwardSettings
import dev.vmd1.gossip.features.settings.Feature
import dev.vmd1.gossip.features.settings.FeatureSettings
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.transport.ConnectionState
import dev.vmd1.gossip.transport.Connectivity
import dev.vmd1.gossip.transport.DeviceConnectivity
import dev.vmd1.gossip.ui.theme.Accent
import dev.vmd1.gossip.ui.theme.ThemeSettings
import kotlinx.coroutines.launch
import dev.vmd1.gossip.service.GossipTileService
import dev.vmd1.gossip.R
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.CheckCircle
import android.os.Build
import android.content.ComponentName
import android.app.StatusBarManager

/** Something to fix for a feature to work, shown at the top of the home sheet with its fix one tap away. */
data class HomeWarning(val title: String, val detail: String, val onFix: () -> Unit)

/**
 * The home screen: one paired device on an atmospheric background (its name, how it is reached, its battery, and what
 * this phone can do with it), over a sheet with what needs fixing, every feature as a tile with its switch, and the
 * way into Settings. The sheet rests at a little under half the screen and drags up to full height.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GossipHome(
    devices: List<TrustedDevice>,
    connectionState: ConnectionState,
    directDeviceIds: Set<String>,
    meshDeviceIds: Set<String>,
    relayedDeviceIds: Set<String>,
    nearbyDeviceIds: Set<String>,
    batteryStates: Map<String, BatteryState>,
    ringingPeers: Set<String>,
    hotspotFor: (deviceId: String) -> HotspotState?,
    myDeviceType: DeviceType,
    paused: Boolean,
    onTogglePause: () -> Unit,
    quietNotification: Boolean,
    onSetQuietNotification: (Boolean) -> Unit,
    warnings: List<HomeWarning>,
    notificationAccessGranted: Boolean,
    onToggleRing: (deviceId: String) -> Unit,
    onTrackpad: (deviceId: String, deviceName: String) -> Unit,
    onMirror: (deviceId: String, deviceName: String) -> Unit,
    onRequestHotspot: (deviceId: String, enable: Boolean) -> Unit,
    onOpen: (SettingsPage) -> Unit,
    onPairNewDevice: () -> Unit,
    onForget: (deviceId: String) -> Unit,
    onSetFallbackHost: (deviceId: String, fallbackHost: String?) -> Unit,
    onSetLockOnLeave: (deviceId: String, enabled: Boolean) -> Unit
) {
    val isPhone = myDeviceType == DeviceType.ANDROID_PHONE
    fun connectivity(id: String) = DeviceConnectivity.classify(id, directDeviceIds, meshDeviceIds, relayedDeviceIds)
    // One device at a time: the one picked, else a connected Mac, else any connected device, else the first.
    var pickedId by rememberSaveable { mutableStateOf<String?>(null) }
    val hero = devices.firstOrNull { it.deviceId == pickedId }
        ?: devices.firstOrNull { it.deviceType == DeviceType.MAC && connectivity(it.deviceId) != Connectivity.NONE }
        ?: devices.firstOrNull { connectivity(it.deviceId) != Connectivity.NONE }
        ?: devices.firstOrNull()
    var settingsForId by remember { mutableStateOf<String?>(null) }

    // The hero is always night-coloured, so the status bar's icons are light over it whatever the system theme.
    val view = LocalView.current
    val dark = isSystemInDarkTheme()
    DisposableEffect(view, dark) {
        val window = (view.context as? Activity)?.window
        window?.let { WindowCompat.getInsetsController(it, view).isAppearanceLightStatusBars = false }
        onDispose { window?.let { WindowCompat.getInsetsController(it, view).isAppearanceLightStatusBars = !dark } }
    }

    val sheet = rememberBottomSheetScaffoldState()
    val scope = rememberCoroutineScope()
    BackHandler(enabled = sheet.bottomSheetState.currentValue == SheetValue.Expanded) {
        scope.launch { sheet.bottomSheetState.partialExpand() }
    }
    val peek = (LocalConfiguration.current.screenHeightDp * 0.42f).dp
    val accent = MaterialTheme.colorScheme.primary

    BottomSheetScaffold(
        scaffoldState = sheet,
        sheetPeekHeight = peek,
        sheetContainerColor = MaterialTheme.colorScheme.surfaceContainerLow,
        sheetContent = {
            HomeSheet(
                warnings = warnings,
                isPhone = isPhone,
                notificationAccessGranted = notificationAccessGranted,
                quietNotification = quietNotification,
                onSetQuietNotification = onSetQuietNotification,
                onOpen = onOpen
            )
        }
    ) {
        Box(Modifier.fillMaxSize().atmosphere(accent)) {
            Column(Modifier.fillMaxSize().statusBarsPadding().padding(bottom = peek)) {
                TopBar(paused = paused, onTogglePause = onTogglePause)
                if (devices.size > 1) {
                    DeviceChips(devices, selected = hero?.deviceId, onPick = { pickedId = it })
                }
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    if (hero == null) {
                        EmptyHero(onPairNewDevice)
                    } else if (paused) {
                        PausedHero(hero, onResume = onTogglePause)
                    } else {
                        val reach = connectivity(hero.deviceId)
                        val ringing = hero.deviceId in ringingPeers
                        Hero(
                            device = hero,
                            reach = reach,
                            connectionState = connectionState,
                            battery = batteryStates[hero.deviceId],
                            nearby = hero.deviceId in nearbyDeviceIds
                        ) {
                            HeroAction(Icons.Default.NotificationsActive, if (ringing) "Stop" else "Ring", accent, ringing) {
                                onToggleRing(hero.deviceId)
                            }
                            if (hero.deviceType == DeviceType.MAC && reach != Connectivity.NONE) {
                                HeroAction(Icons.Default.TouchApp, "Trackpad", accent) { onTrackpad(hero.deviceId, hero.deviceName) }
                            }
                            // Android → Android mirroring needs the same network.
                            if (hero.deviceType != DeviceType.MAC && reach == Connectivity.DIRECT) {
                                HeroAction(Icons.Default.Cast, "Mirror", accent) { onMirror(hero.deviceId, hero.deviceName) }
                            }
                            if (hero.deviceType == DeviceType.ANDROID_PHONE) {
                                hotspotFor(hero.deviceId)?.let { hotspot ->
                                    HeroAction(
                                        if (hotspot.enabled) Icons.Default.WifiTethering else Icons.Default.WifiTetheringOff,
                                        "Hotspot", accent, hotspot.enabled
                                    ) { onRequestHotspot(hero.deviceId, !hotspot.enabled) }
                                }
                            }
                            HeroAction(Icons.Default.ContentPaste, "Clipboard", accent) { onOpen(SettingsPage.CLIPBOARD_HOME) }
                            HeroAction(Icons.Default.MoreHoriz, "More", accent) { settingsForId = hero.deviceId }
                        }
                    }
                }
            }
        }
    }

    devices.firstOrNull { it.deviceId == settingsForId }?.let { device ->
        DeviceSettingsSheet(
            device = device,
            onSetFallbackHost = onSetFallbackHost,
            // Only phones are seen over Bluetooth, and nothing locks a phone this way.
            showLockOnLeaveToggle = isPhone && device.deviceType != DeviceType.ANDROID_PHONE,
            onSetLockOnLeave = onSetLockOnLeave,
            onForget = {
                onForget(device.deviceId)
                settingsForId = null
            },
            onDismiss = { settingsForId = null }
        )
    }
}

// MARK: - Hero

/** Gossip's name and version, and its power button: pauses everything (connections, Bluetooth, sharing) or resumes. */
@Composable
private fun TopBar(paused: Boolean, onTogglePause: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f)) {
            Text("Gossip", style = MaterialTheme.typography.titleMedium, color = Color.White, fontWeight = FontWeight.SemiBold)
            Text(BuildConfig.VERSION_NAME, style = MaterialTheme.typography.labelSmall, color = Color.White.copy(alpha = 0.6f))
        }
        Surface(
            onClick = onTogglePause,
            shape = CircleShape,
            color = if (paused) Color.Transparent else Color.White.copy(alpha = 0.12f),
            border = BorderStroke(1.dp, Color.White.copy(alpha = if (paused) 0.25f else 0.45f)),
            modifier = Modifier.size(40.dp)
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    Icons.Default.PowerSettingsNew,
                    contentDescription = if (paused) "Resume Gossip" else "Pause Gossip",
                    tint = Color.White.copy(alpha = if (paused) 0.55f else 1f),
                    modifier = Modifier.size(20.dp)
                )
            }
        }
    }
}

/** With several paired devices, which one the hero shows. */
@Composable
private fun DeviceChips(devices: List<TrustedDevice>, selected: String?, onPick: (String) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 20.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        devices.forEach { device ->
            val on = device.deviceId == selected
            Surface(
                onClick = { onPick(device.deviceId) },
                shape = RoundedCornerShape(50),
                color = Color.White.copy(alpha = if (on) 0.25f else 0.1f)
            ) {
                Row(Modifier.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(device.deviceType.icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                    Text(" ${device.deviceName}", style = MaterialTheme.typography.labelLarge, color = Color.White)
                }
            }
        }
    }
}

@Composable
private fun Hero(
    device: TrustedDevice,
    reach: Connectivity,
    connectionState: ConnectionState,
    battery: BatteryState?,
    nearby: Boolean,
    actions: @Composable RowScope.() -> Unit
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(device.deviceType.icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(56.dp))
        Spacer(Modifier.height(10.dp))
        Text(device.deviceName, style = MaterialTheme.typography.headlineSmall, color = Color.White, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(10.dp))
        StatusPill(reach, connectionState, battery, nearby)
        Spacer(Modifier.height(32.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), content = actions)
    }
}

/** How the device is reached, in words, with its battery: "Local network · 82% ⚡". */
@Composable
private fun StatusPill(reach: Connectivity, connectionState: ConnectionState, battery: BatteryState?, nearby: Boolean) {
    val (dot, text) = when (reach) {
        Connectivity.DIRECT -> Color(0xFF34C759) to "Local network"
        Connectivity.RELAYED -> Color(0xFF30B0C7) to "Through the relay"
        Connectivity.MESH -> Color(0xFF0A84FF) to "Through another device"
        Connectivity.NONE -> Color(0xFF8E8E93) to when (connectionState) {
            ConnectionState.HANDSHAKING -> "Connecting…"
            ConnectionState.DISCOVERING -> "Looking for it…"
            else -> "Not connected"
        }
    }
    Surface(shape = RoundedCornerShape(50), color = Color.White.copy(alpha = 0.12f)) {
        Row(Modifier.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(7.dp).background(dot, CircleShape))
            val detail = buildList {
                add(text)
                battery?.let { add("${it.level}%") }
                if (nearby) add("Nearby")
            }.joinToString(" · ")
            Text("  $detail", style = MaterialTheme.typography.labelLarge, color = Color.White.copy(alpha = 0.9f))
            if (battery?.isCharging == true) {
                Icon(Icons.Default.Bolt, contentDescription = "charging", tint = Color.White, modifier = Modifier.size(14.dp))
            }
        }
    }
}

@Composable
private fun HeroAction(icon: ImageVector, label: String, accent: Color, active: Boolean = false, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.width(60.dp)) {
        Surface(
            onClick = onClick,
            shape = CircleShape,
            color = if (active) accent.copy(alpha = 0.6f) else Color.White.copy(alpha = 0.12f),
            border = BorderStroke(1.dp, Color.White.copy(alpha = if (active) 0.45f else 0.16f)),
            modifier = Modifier.size(52.dp)
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(icon, contentDescription = label, tint = Color.White, modifier = Modifier.size(22.dp))
            }
        }
        Spacer(Modifier.height(6.dp))
        Text(label, style = MaterialTheme.typography.labelSmall, color = Color.White.copy(alpha = 0.85f), maxLines = 1)
    }
}

/** Gossip paused: the device dimmed, and the way back. */
@Composable
private fun PausedHero(device: TrustedDevice, onResume: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(device.deviceType.icon, contentDescription = null, tint = Color.White.copy(alpha = 0.45f), modifier = Modifier.size(56.dp))
        Spacer(Modifier.height(10.dp))
        Text(device.deviceName, style = MaterialTheme.typography.headlineSmall, color = Color.White.copy(alpha = 0.6f), fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(10.dp))
        Surface(shape = RoundedCornerShape(50), color = Color.White.copy(alpha = 0.12f)) {
            Text(
                "Paused · nothing is shared",
                style = MaterialTheme.typography.labelLarge,
                color = Color.White.copy(alpha = 0.8f),
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp)
            )
        }
        Spacer(Modifier.height(28.dp))
        Button(
            onClick = onResume,
            colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Color(0xFF111522))
        ) {
            Icon(Icons.Default.PlayArrow, contentDescription = null, modifier = Modifier.size(18.dp))
            Text("  Resume")
        }
    }
}

@Composable
private fun EmptyHero(onPairNewDevice: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(Icons.Default.Devices, contentDescription = null, tint = Color.White, modifier = Modifier.size(56.dp))
        Spacer(Modifier.height(10.dp))
        Text("No devices yet", style = MaterialTheme.typography.headlineSmall, color = Color.White, fontWeight = FontWeight.SemiBold)
        Text("Pair your Mac to get started", style = MaterialTheme.typography.bodyMedium, color = Color.White.copy(alpha = 0.7f))
        Spacer(Modifier.height(20.dp))
        Button(
            onClick = onPairNewDevice,
            colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Color(0xFF111522))
        ) { Text("Pair a device") }
    }
}

/** Night sky tinted by the accent, with a dot grain that fades in toward the bottom (after Rabbit Link's home). */
private fun Modifier.atmosphere(accent: Color): Modifier = drawWithCache {
    val night = Color(0xFF0B0D16)
    val base = Brush.verticalGradient(
        0f to lerp(accent, Color(0xFF1C2238), 0.72f),
        0.55f to Color(0xFF111522),
        1f to night
    )
    val glow = Brush.radialGradient(
        listOf(accent.copy(alpha = 0.42f), Color.Transparent),
        center = Offset(size.width * 0.25f, size.height * 0.04f),
        radius = size.width * 1.1f
    )
    val haze = Brush.radialGradient(
        listOf(Color(0xFFC8D2FF).copy(alpha = 0.2f), Color.Transparent),
        center = Offset(size.width * 0.85f, size.height * 0.2f),
        radius = size.width * 0.75f
    )
    val step = 6.dp.toPx()
    val top = size.height * 0.35f
    val bands = List(6) { mutableListOf<Offset>() }
    var y = top
    while (y < size.height) {
        val band = (((y - top) / (size.height - top)) * bands.size).toInt().coerceIn(0, bands.lastIndex)
        var x = step / 2
        while (x < size.width) {
            bands[band].add(Offset(x, y))
            x += step
        }
        y += step
    }
    val dot = 1.6.dp.toPx()
    onDrawBehind {
        drawRect(base)
        drawRect(glow)
        drawRect(haze)
        bands.forEachIndexed { i, points ->
            drawPoints(points, PointMode.Points, Color.White.copy(alpha = 0.02f + 0.012f * i), strokeWidth = dot, cap = StrokeCap.Round)
        }
    }
}

// MARK: - Sheet

@Composable
private fun HomeSheet(
    warnings: List<HomeWarning>,
    isPhone: Boolean,
    notificationAccessGranted: Boolean,
    quietNotification: Boolean,
    onSetQuietNotification: (Boolean) -> Unit,
    onOpen: (SettingsPage) -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp)
            .padding(bottom = 24.dp)
            .navigationBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        if (warnings.isEmpty()) AllSetRow { onOpen(SettingsPage.PERMISSIONS) } else warnings.forEach { WarningRow(it) }
        FeatureTiles(isPhone, notificationAccessGranted, onOpen)
        SectionLabel("Settings")
        SettingsMenuRow("Devices & pairing", "Pair a device, show your QR code, run setup again") { onOpen(SettingsPage.DEVICES) }
        SettingsMenuRow("Relay", "Stay connected when your devices are not on the same network") { onOpen(SettingsPage.RELAY) }
        SettingsMenuRow("Permissions", "Notifications, Do Not Disturb, Bluetooth and more") { onOpen(SettingsPage.PERMISSIONS) }
        SettingsMenuRow("All features", "Every switch, with clipboard history") { onOpen(SettingsPage.FEATURES) }
        ThemeRow()
        SwitchRow("Quiet notification", "Keep Gossip's status out of the status bar", quietNotification, onSetQuietNotification)
        AddTileRow()
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = 4.dp, top = 6.dp)
    )
}

/** Nothing to fix: says so, and leads to the checklist. */
@Composable
private fun AllSetRow(onClick: () -> Unit) {
    val dark = isSystemInDarkTheme()
    val background = if (dark) Color(0xFF13301E) else Color(0xFFDDF5E4)
    val foreground = if (dark) Color(0xFF8FE0A8) else Color(0xFF14532D)
    Surface(onClick = onClick, shape = RoundedCornerShape(16.dp), color = background, modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.CheckCircle, contentDescription = null, tint = foreground)
            Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                Text("Everything is allowed", style = MaterialTheme.typography.titleSmall, color = foreground)
                Text("Every feature has the access it needs", style = MaterialTheme.typography.bodySmall, color = foreground.copy(alpha = 0.8f))
            }
        }
    }
}

@Composable
private fun SwitchRow(title: String, detail: String, checked: Boolean, onChecked: (Boolean) -> Unit) {
    Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceVariant, modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleMedium)
                Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Switch(checked = checked, onCheckedChange = onChecked)
        }
    }
}

/** Android 13+: asks System UI to add the Quick Settings tile, the way the system's own add-tile prompt does. */
@Composable
private fun AddTileRow() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
    val context = LocalContext.current
    SettingsMenuRow("Quick Settings tile", "Pause or resume Gossip from the quick settings") {
        context.getSystemService(StatusBarManager::class.java)?.requestAddTileService(
            ComponentName(context, GossipTileService::class.java),
            "Gossip",
            android.graphics.drawable.Icon.createWithResource(context, R.drawable.ic_tile_gossip),
            context.mainExecutor
        ) { }
    }
}

@Composable
private fun WarningRow(warning: HomeWarning) {
    val dark = isSystemInDarkTheme()
    val background = if (dark) Color(0xFF3A2B12) else Color(0xFFFFF0D2)
    val foreground = if (dark) Color(0xFFFFD38A) else Color(0xFF6B4500)
    Surface(onClick = warning.onFix, shape = RoundedCornerShape(16.dp), color = background, modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Warning, contentDescription = null, tint = foreground)
            Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                Text(warning.title, style = MaterialTheme.typography.titleSmall, color = foreground)
                Text(warning.detail, style = MaterialTheme.typography.bodySmall, color = foreground.copy(alpha = 0.8f))
            }
            Text("Fix", style = MaterialTheme.typography.labelLarge, color = foreground, fontWeight = FontWeight.SemiBold)
        }
    }
}

private data class Tile(
    val icon: ImageVector,
    val title: String,
    /** A state worth a line ("Needs access"); on and off are the switch's to say. */
    val status: String?,
    val checked: Boolean,
    val onChecked: (Boolean) -> Unit,
    /** The feature's own page, opened by tapping the tile; without one the tap flips the switch. */
    val page: SettingsPage? = null
)

/** Every feature as a tile: its switch for this device, its state, and its own page where it has one. */
@Composable
private fun FeatureTiles(isPhone: Boolean, notificationAccessGranted: Boolean, onOpen: (SettingsPage) -> Unit) {
    val context = LocalContext.current
    val features = remember { FeatureSettings.getInstance(context) }
    val disabled by features.disabled.collectAsState()
    val messages = remember { MessagesSettings.getInstance(context) }
    val messagesOn by messages.enabled.collectAsState()
    val forwarding = remember { NotificationForwardSettings.getInstance(context) }
    val blocked by forwarding.blocked.collectAsState()

    fun tile(feature: Feature, icon: ImageVector, title: String = feature.title, status: String? = null, page: SettingsPage? = null): Tile {
        val on = feature !in disabled
        return Tile(icon, title, status, on, { features.setEnabled(feature, it) }, page)
    }
    val tiles = buildList {
        if (isPhone) {
            val status: String? = when {
                Feature.NOTIFICATIONS in disabled -> null
                !notificationAccessGranted -> "Needs access"
                blocked.isEmpty() -> "Every app"
                else -> "${blocked.size} apps left out"
            }
            add(tile(Feature.NOTIFICATIONS, Icons.Default.Notifications, status = status, page = SettingsPage.NOTIFICATIONS))
        }
        add(tile(Feature.CLIPBOARD, Icons.Default.ContentPaste, page = SettingsPage.CLIPBOARD_HOME))
        add(tile(Feature.MEDIA, Icons.Default.MusicNote, title = "Media"))
        add(tile(Feature.DND, Icons.Default.DoNotDisturbOn))
        if (isPhone) {
            add(Tile(Icons.Default.Sms, "Messages", null, messagesOn, messages::setEnabled, SettingsPage.MESSAGES))
            add(tile(Feature.HOTSPOT, Icons.Default.WifiTethering, title = "Hotspot", page = SettingsPage.HOTSPOT))
        }
        add(tile(Feature.LOCK_ON_LEAVE, Icons.Default.Lock))
        add(tile(Feature.SCREEN_MIRRORING, Icons.AutoMirrored.Filled.ScreenShare, title = "Mirroring"))
        add(tile(Feature.UNIVERSAL_CONTROL, Icons.Default.Mouse))
        add(tile(Feature.FIND_DEVICE, Icons.Default.NotificationsActive, title = "Find device"))
        add(tile(Feature.BATTERY, Icons.Default.BatteryChargingFull, title = "Battery"))
    }

    SectionLabel("Features")
    tiles.chunked(2).forEach { row ->
        // Both tiles of a row as tall as the taller one (one may have a state line).
        Row(Modifier.height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            row.forEach { FeatureTile(it, onOpen, Modifier.weight(1f).fillMaxHeight()) }
            if (row.size == 1) Spacer(Modifier.weight(1f))
        }
    }
}

@Composable
private fun FeatureTile(tile: Tile, onOpen: (SettingsPage) -> Unit, modifier: Modifier) {
    val scheme = MaterialTheme.colorScheme
    Surface(
        onClick = { tile.page?.let(onOpen) ?: tile.onChecked(!tile.checked) },
        shape = RoundedCornerShape(20.dp),
        color = if (tile.checked) scheme.primary.copy(alpha = 0.16f).compositeOver(scheme.surfaceContainerHigh) else scheme.surfaceContainerHigh,
        modifier = modifier
    ) {
        Column(Modifier.padding(start = 14.dp, end = 6.dp, top = 6.dp, bottom = 12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(tile.icon, contentDescription = null, tint = if (tile.checked) scheme.primary else scheme.onSurfaceVariant)
                Spacer(Modifier.weight(1f))
                Switch(checked = tile.checked, onCheckedChange = tile.onChecked, modifier = Modifier.scale(0.75f))
            }
            Text(tile.title, style = MaterialTheme.typography.titleSmall, maxLines = 1)
            tile.status?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = scheme.onSurfaceVariant, maxLines = 1) }
        }
    }
}

/** The accent: System (the wallpaper's colours) or one of four. */
@Composable
private fun ThemeRow() {
    val context = LocalContext.current
    val settings = remember { ThemeSettings.getInstance(context) }
    val accent by settings.accent.collectAsState()
    Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceVariant, modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Theme", style = MaterialTheme.typography.titleMedium)
                Text(accent.label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Accent.entries.forEach { option ->
                val brush = if (option == Accent.SYSTEM) {
                    Brush.sweepGradient(listOf(Color(0xFFFF6B35), Color(0xFF10A37F), Color(0xFF0A84FF), Color(0xFF8E5CF6), Color(0xFFFF6B35)))
                } else {
                    SolidColor(option.color)
                }
                Box(
                    Modifier
                        .padding(start = 8.dp)
                        .size(26.dp)
                        .then(if (option == accent) Modifier.border(2.dp, MaterialTheme.colorScheme.onSurface, CircleShape) else Modifier)
                        .padding(3.dp)
                        .background(brush, CircleShape)
                        .clickable { settings.setAccent(option) }
                        .semantics { contentDescription = "${option.label} theme" }
                )
            }
        }
    }
}
