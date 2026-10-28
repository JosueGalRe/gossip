package dev.vmd1.gossip.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.TabletMac
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import dev.vmd1.gossip.crypto.TrustedDevice
import dev.vmd1.gossip.features.battery.BatteryState
import dev.vmd1.gossip.features.battery.BatterySyncManager
import dev.vmd1.gossip.features.hotspot.HotspotState
import androidx.compose.material.icons.filled.Battery2Bar
import androidx.compose.material.icons.filled.Battery3Bar
import androidx.compose.material.icons.filled.Battery4Bar
import androidx.compose.material.icons.filled.Battery5Bar
import androidx.compose.material.icons.filled.Battery6Bar
import androidx.compose.material.icons.filled.BatteryAlert
import androidx.compose.material.icons.filled.BatteryChargingFull
import androidx.compose.material.icons.filled.BatteryFull
import dev.vmd1.gossip.protocol.DeviceType

/** A device type's glyph: a laptop for a Mac, a phone or a tablet. */
internal val DeviceType.icon: ImageVector
    get() = when (this) {
        DeviceType.MAC -> Icons.Default.Laptop
        DeviceType.ANDROID_PHONE -> Icons.Default.PhoneAndroid
        DeviceType.ANDROID_TABLET -> Icons.Default.TabletMac
    }

private const val HOTSPOT_OVERRIDE_MS = 30_000L

/** Battery glyph for a reported level: charging bolt, low-battery alert, else a level-matched bar icon. */
internal fun batteryIcon(b: BatteryState): ImageVector = when {
    b.isCharging -> Icons.Default.BatteryChargingFull
    b.level <= BatterySyncManager.LOW_THRESHOLD -> Icons.Default.BatteryAlert
    b.level >= 95 -> Icons.Default.BatteryFull
    b.level >= 80 -> Icons.Default.Battery6Bar
    b.level >= 65 -> Icons.Default.Battery5Bar
    b.level >= 50 -> Icons.Default.Battery4Bar
    b.level >= 35 -> Icons.Default.Battery3Bar
    else -> Icons.Default.Battery2Bar
}

/** A paired phone's Instant Hotspot as this device sees it, or `null` when nothing reports it. Prefers the BLE-observed
 *  on/off bit when nearby: it stays live with no mesh connection at all, unlike [hotspotStates] (mesh-only, stale the
 *  moment the mesh connection drops), and keeps the mesh report's SSID. Both lag a real toggle by several seconds, so
 *  what the phone itself just confirmed over GATT ([hotspotOverrides]) wins until they agree, or 30 s pass. */
internal fun mergedHotspotState(
    deviceId: String,
    nearbyDeviceIds: Set<String>,
    bleHotspotOnStates: Map<String, Boolean>,
    hotspotStates: Map<String, HotspotState>,
    hotspotOverrides: Map<String, Pair<Boolean, Long>>
): HotspotState? {
    val bleOn = if (deviceId in nearbyDeviceIds) bleHotspotOnStates[deviceId] else null
    val meshState = hotspotStates[deviceId]
    val underlying = when {
        bleOn != null && meshState != null -> meshState.copy(enabled = bleOn)
        bleOn != null -> HotspotState(enabled = bleOn)
        else -> meshState
    }
    val override = hotspotOverrides[deviceId]
    return if (override != null && System.currentTimeMillis() - override.second < HOTSPOT_OVERRIDE_MS &&
        underlying?.enabled != override.first
    ) HotspotState(override.first, if (override.first) underlying?.ssid else null) else underlying
}

/** One paired device's own settings, in a bottom sheet: a fallback address for reaching it off the local network
 *  (e.g. a Tailscale IP, see `SyncForegroundService.runFallbackDialLoop`), Lock-on-Leave, and forgetting it. */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
internal fun DeviceSettingsSheet(
    device: TrustedDevice,
    onSetFallbackHost: (deviceId: String, fallbackHost: String?) -> Unit,
    showLockOnLeaveToggle: Boolean,
    onSetLockOnLeave: (deviceId: String, enabled: Boolean) -> Unit,
    onForget: () -> Unit,
    onDismiss: () -> Unit
) {
    var showForgetConfirmation by remember { mutableStateOf(false) }
    // Hoisted so dismissing the sheet also saves it, not just the keyboard's Done key.
    var fallbackText by remember(device.deviceId) { mutableStateOf(device.fallbackHost.orEmpty()) }
    fun saveFallback() {
        if (fallbackText.trim() != device.fallbackHost.orEmpty()) onSetFallbackHost(device.deviceId, fallbackText)
    }
    fun commitAndDismiss() { saveFallback(); onDismiss() }

    androidx.compose.material3.ModalBottomSheet(onDismissRequest = ::commitAndDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 24.dp, end = 24.dp, bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text(device.deviceName, style = MaterialTheme.typography.titleLarge)

            FallbackHostField(text = fallbackText, onTextChange = { fallbackText = it }, onCommit = ::saveFallback)

            // Per-pair, BLE-driven: lock this specific Mac/tablet when this (phone) device
            // leaves its BLE range (see docs/ble-proximity-protocol.md / schema/message-
            // types.md's lock_on_leave.config). Only meaningful when I'm a phone (only
            // phones are BLE-detectable — see BLEProximityMonitor's role split) and the
            // target isn't a phone (nothing locks a phone this way).
            if (showLockOnLeaveToggle) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("Lock this device when I leave")
                    Switch(
                        checked = device.lockOnLeaveEnabled,
                        onCheckedChange = { onSetLockOnLeave(device.deviceId, it) }
                    )
                }
            }

            OutlinedButton(
                onClick = { showForgetConfirmation = true },
                colors = androidx.compose.material3.ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)
            ) {
                Text("Forget This Device…")
            }
        }
    }

    if (showForgetConfirmation) {
        AlertDialog(
            onDismissRequest = { showForgetConfirmation = false },
            title = { Text("Forget ${device.deviceName}?") },
            text = { Text("This device will no longer trust ${device.deviceName}. You'll need to pair again to reconnect.") },
            confirmButton = {
                TextButton(onClick = onForget) { Text("Forget") }
            },
            dismissButton = {
                TextButton(onClick = { showForgetConfirmation = false }) { Text("Cancel") }
            }
        )
    }
}

/** Editable field for [TrustedDevice.fallbackHost]. The owner holds the text and saves it; this calls
 *  [onCommit] on the keyboard's Done key and ~0.8s after the user stops typing (so a fallback dial
 *  never fires against a half-typed address on every keystroke, but a value is never lost just
 *  because the dialog was closed without pressing the keyboard's Done key). */
@Composable
private fun FallbackHostField(
    text: String,
    onTextChange: (String) -> Unit,
    onCommit: () -> Unit,
    modifier: Modifier = Modifier.fillMaxWidth()
) {
    androidx.compose.runtime.LaunchedEffect(text) {
        kotlinx.coroutines.delay(800)
        onCommit()
    }
    OutlinedTextField(
        value = text,
        onValueChange = onTextChange,
        label = { Text("Fallback IP (e.g. Tailscale)") },
        placeholder = { Text("100.x.x.x") },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { onCommit() }),
        modifier = modifier
    )
}
