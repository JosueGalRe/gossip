package dev.vmd1.gossip.service

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import dev.vmd1.gossip.features.battery.BatteryState
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.transport.Connectivity
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** What Gossip is doing, in one place, for the status notification, the Quick Settings tile, the widget and the home. */
data class GossipStatus(
    val paused: Boolean = false,
    val deviceId: String? = null,
    val deviceName: String? = null,
    val deviceType: DeviceType? = null,
    val reach: Connectivity = Connectivity.NONE,
    val battery: BatteryState? = null,
    val searching: Boolean = false
) {
    val connected: Boolean get() = reach != Connectivity.NONE

    /** "Local network · 82%", "Through the relay", "Looking for MacBook…", "Paused". */
    val summary: String
        get() = when {
            paused -> "Paused"
            deviceName == null -> "No devices paired"
            !connected -> if (searching) "Looking for $deviceName…" else "Not connected"
            else -> listOfNotNull(
                when (reach) {
                    Connectivity.DIRECT -> "Local network"
                    Connectivity.RELAYED -> "Through the relay"
                    else -> "Through another device"
                },
                battery?.let { "${it.level}%" + if (it.isCharging) " ⚡" else "" }
            ).joinToString(" · ")
        }
}

/**
 * Gossip's on/off switch and its published [status]. Paused means the sync service is stopped (connections, Bluetooth,
 * notification and clipboard sharing all end) and stays stopped, across reboots, until resumed. Kept here rather than
 * in the service so the tile, the widget and the home screen read and drive it whether the service runs or not.
 */
class GossipControl private constructor(private val context: Context) {
    private val prefs = context.getSharedPreferences("gossip_control", Context.MODE_PRIVATE)
    private val _status = MutableStateFlow(GossipStatus(paused = prefs.getBoolean(KEY_PAUSED, false)))
    val status: StateFlow<GossipStatus> = _status

    private val _quiet = MutableStateFlow(prefs.getBoolean(KEY_QUIET, false))
    /** The status notification kept out of the status bar (its channel at minimum importance). */
    val quiet: StateFlow<Boolean> = _quiet

    val isPaused: Boolean get() = _status.value.paused

    fun pause() {
        prefs.edit().putBoolean(KEY_PAUSED, true).apply()
        publish(GossipStatus(paused = true))
        context.stopService(Intent(context, SyncForegroundService::class.java))
    }

    fun resume() {
        markResumed()
        ContextCompat.startForegroundService(context, Intent(context, SyncForegroundService::class.java))
    }

    /** The service is starting on its own (a resume intent from the widget): only the flag changes here. */
    internal fun markResumed() {
        prefs.edit().putBoolean(KEY_PAUSED, false).apply()
        if (isPaused) publish(GossipStatus())
    }

    fun setQuiet(quiet: Boolean) {
        prefs.edit().putBoolean(KEY_QUIET, quiet).apply()
        _quiet.value = quiet
    }

    /** From the running service: the paired device it shows and how it is reached. */
    internal fun publish(status: GossipStatus) {
        if (_status.value == status) return
        _status.value = status
        GossipTileService.refresh(context)
        dev.vmd1.gossip.ui.GossipWidget.refresh(context)
    }

    companion object {
        private const val KEY_PAUSED = "paused"
        private const val KEY_QUIET = "quietNotification"

        @Volatile private var instance: GossipControl? = null
        fun getInstance(context: Context): GossipControl = instance ?: synchronized(this) {
            instance ?: GossipControl(context.applicationContext).also { instance = it }
        }
    }
}
