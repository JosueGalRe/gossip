package dev.vmd1.gossip.ui

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import dev.vmd1.gossip.R
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.service.GossipControl
import dev.vmd1.gossip.service.SyncForegroundService

/**
 * Home screen widget: the paired device, how it is reached and its battery, with Ring (Resume while Gossip is paused).
 * Drawn from [GossipControl.status], and redrawn only when it changes (no polling).
 */
class GossipWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        manager.updateAppWidget(ids, views(context))
    }

    companion object {
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context) ?: return
            val ids = manager.getAppWidgetIds(ComponentName(context, GossipWidget::class.java))
            if (ids.isNotEmpty()) manager.updateAppWidget(ids, views(context))
        }

        private fun views(context: Context): RemoteViews {
            val status = GossipControl.getInstance(context).status.value
            val views = RemoteViews(context.packageName, R.layout.widget_gossip)
            views.setImageViewResource(
                R.id.widget_icon,
                if (status.deviceType == DeviceType.MAC || status.deviceType == null) R.drawable.ic_widget_laptop else R.drawable.ic_widget_phone
            )
            views.setTextViewText(R.id.widget_title, status.deviceName ?: "Gossip")
            views.setTextViewText(R.id.widget_status, status.summary)
            views.setOnClickPendingIntent(
                R.id.widget_root,
                PendingIntent.getActivity(
                    context, 0,
                    Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
            )
            // Starting the service is the resume; ringing goes through it too (a widget tap may start it in the background).
            val action = when {
                status.paused -> Intent(context, SyncForegroundService::class.java).setAction(SyncForegroundService.ACTION_RESUME)
                status.deviceId != null && status.connected -> Intent(context, SyncForegroundService::class.java)
                    .setAction(SyncForegroundService.ACTION_RING).putExtra(SyncForegroundService.EXTRA_DEVICE_ID, status.deviceId)
                else -> null
            }
            views.setViewVisibility(R.id.widget_action, if (action == null) android.view.View.GONE else android.view.View.VISIBLE)
            if (action != null) {
                views.setImageViewResource(R.id.widget_action, if (status.paused) R.drawable.ic_widget_play else R.drawable.ic_widget_ring)
                views.setContentDescription(R.id.widget_action, if (status.paused) "Resume Gossip" else "Ring ${status.deviceName}")
                views.setOnClickPendingIntent(
                    R.id.widget_action,
                    PendingIntent.getForegroundService(context, 1, action, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                )
            }
            return views
        }
    }
}
