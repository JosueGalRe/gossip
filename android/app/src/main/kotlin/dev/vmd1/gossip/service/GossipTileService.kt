package dev.vmd1.gossip.service

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import dev.vmd1.gossip.R
import dev.vmd1.gossip.ui.MainActivity
import dev.vmd1.gossip.util.Log

/** Quick Settings tile: the paired device and how it is reached; a tap pauses or resumes Gossip, a long press opens it. */
class GossipTileService : TileService() {
    override fun onStartListening() = render()

    override fun onClick() {
        val control = GossipControl.getInstance(this)
        if (!control.isPaused) {
            control.pause()
        } else {
            try {
                control.resume()
            } catch (e: Exception) {
                // Starting a foreground service from the background can be refused; the app resumes it instead.
                Log.w(TAG, "Couldn't resume from the tile: ${e.message}")
                openApp()
            }
        }
        render()
    }

    private fun openApp() {
        val intent = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
        } else {
            @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
            startActivityAndCollapse(intent)
        }
    }

    private fun render() {
        val tile = qsTile ?: return
        val status = GossipControl.getInstance(this).status.value
        tile.state = if (status.paused || !status.connected) Tile.STATE_INACTIVE else Tile.STATE_ACTIVE
        tile.label = status.deviceName ?: "Gossip"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) tile.subtitle = status.summary
        tile.icon = Icon.createWithResource(this, R.drawable.ic_tile_gossip)
        tile.updateTile()
    }

    companion object {
        private const val TAG = "GossipTile"

        /** Asks System UI to redraw the tile (it listens only on request, see the manifest's ACTIVE_TILE). */
        fun refresh(context: Context) {
            runCatching { requestListeningState(context, ComponentName(context, GossipTileService::class.java)) }
        }
    }
}
