package dev.vmd1.gossip.features.filetransfer

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.core.content.ContextCompat
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.service.SyncForegroundService
import dev.vmd1.gossip.transport.TransportManagerHolder

/** Only destination selection lives here; a grant-bearing service intent keeps shared Uris readable after finish(). */
class ShareFilesActivity : Activity() {
    @Suppress("DEPRECATION")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uris = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
            Intent.ACTION_SEND_MULTIPLE -> intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
            else -> { finish(); return }
        }.ifEmpty {
            intent.clipData?.let { clip -> (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri } }.orEmpty()
        }.filter { it.scheme == "content" }.distinct()
        if (uris.isEmpty()) {
            dev.vmd1.gossip.util.Log.w("ShareFiles", "Nothing to send: action=${intent.action} type=${intent.type}")
            Toast.makeText(this, "Share a file to send it to your Mac.", Toast.LENGTH_LONG).show()
            finish(); return
        }
        val transport = TransportManagerHolder.instance
        val trusted = TrustedDevicesStore.getInstance(this)
        val devices = trusted.allDevices().filter {
            it.deviceType == DeviceType.MAC && !trusted.isProvisional(it.deviceId) &&
                it.deviceId in (transport?.connectedDeviceIds?.value ?: emptySet())
        }
        if (devices.isEmpty()) {
            // Why no Mac qualified: release builds keep only warnings, and this is the one place the reason shows.
            dev.vmd1.gossip.util.Log.w("ShareFiles", "No Mac to send to: transport=${transport != null} " +
                "direct=${transport?.connectedDeviceIds?.value?.size} relayed=${transport?.relayedDeviceIds?.value?.size} " +
                "macs=${trusted.allDevices().count { it.deviceType == DeviceType.MAC }} " +
                "provisional=${trusted.allDevices().count { trusted.isProvisional(it.deviceId) }}")
        }
        when (devices.size) {
            0 -> {
                Toast.makeText(this, "Your Mac must be connected to Gossip on the same network.", Toast.LENGTH_LONG).show()
                finish()
            }
            1 -> handOff(devices.single().deviceId, uris)
            else -> AlertDialog.Builder(this).setTitle("Send to Mac")
                .setItems(devices.map { it.deviceName }.toTypedArray()) { _, index -> handOff(devices[index].deviceId, uris) }
                .setOnCancelListener { finish() }.show()
        }
    }

    private fun handOff(peer: String, uris: List<Uri>) {
        val clip = ClipData.newRawUri("Shared files", uris.first()).apply {
            uris.drop(1).forEach { addItem(ClipData.Item(it)) }
        }
        try {
            ContextCompat.startForegroundService(this, Intent(this, SyncForegroundService::class.java).apply {
                action = SyncForegroundService.ACTION_SEND_FILES
                putExtra(SyncForegroundService.EXTRA_DEVICE_ID, peer)
                clipData = clip
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            })
        } catch (e: Exception) {
            dev.vmd1.gossip.util.Log.w("ShareFiles", "Couldn't start the transfer", e)
            Toast.makeText(this, "Couldn't start file transfer: ${e.message}", Toast.LENGTH_LONG).show()
        }
        finish()
    }
}
