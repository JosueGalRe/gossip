package dev.vmd1.gossip.features.filetransfer

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.app.NotificationCompat
import dev.vmd1.gossip.service.SyncForegroundService

/** Notification tags are transfer UUIDs, so concurrent incoming and outgoing files never replace each other. */
class FileTransferNotifications(private val context: Context) {
    private val manager = context.getSystemService(NotificationManager::class.java)

    init {
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "File transfers", NotificationManager.IMPORTANCE_DEFAULT))
    }

    fun sending(id: String, name: String, peerName: String, progress: Int) {
        val cancel = PendingIntent.getService(context, 0,
            Intent(context, SyncForegroundService::class.java)
                .setAction(SyncForegroundService.ACTION_CANCEL_FILE)
                .setData(Uri.parse("gossip:cancel/$id"))
                .putExtra(SyncForegroundService.EXTRA_TRANSFER_ID, id),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        post(id, builder("Sending $name", "To $peerName")
            .setOngoing(true).setOnlyAlertOnce(true).setProgress(100, progress, false)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Cancel", cancel))
    }

    fun sent(id: String, name: String, peerName: String) {
        post(id, builder("Sent $name", "To $peerName").setAutoCancel(true))
    }

    fun failed(id: String, name: String, reason: String) {
        post(id, builder("Couldn't send $name", reason).setAutoCancel(true))
    }

    fun received(id: String, name: String, peerName: String, uri: Uri, mime: String) {
        val view = PendingIntent.getActivity(context, 0,
            Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        post(id, builder("Received $name", "From $peerName").setAutoCancel(true).setContentIntent(view))
    }

    private fun builder(title: String, text: String) = NotificationCompat.Builder(context, CHANNEL)
        .setSmallIcon(android.R.drawable.stat_sys_download_done)
        .setContentTitle(title).setContentText(text)

    private fun post(id: String, builder: NotificationCompat.Builder) {
        // Notification permission is optional: denying it must not turn a successfully saved file into a failed transfer.
        runCatching { manager.notify(id, 0, builder.build()) }
    }

    private companion object { const val CHANNEL = "gossip_file_transfers" }
}
