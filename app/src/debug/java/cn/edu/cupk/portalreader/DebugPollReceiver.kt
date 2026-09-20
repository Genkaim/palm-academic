package cn.edu.cupk.portalreader

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationManagerCompat
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager

/** Debug-only hook used by the localhost EAMS simulator test script. */
class DebugPollReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            ACTION_PREPARE -> {
                val preferences = PortalNotificationPreferences.preferences(context)
                preferences.edit().clear().apply {
                    PortalNotificationPreferences.notificationKeys.forEach { putBoolean(it, true) }
                    putBoolean(PortalPollWorker.KEY_MONITOR_ENABLED, true)
                    putBoolean(PortalNotificationPreferences.KEY_PERSISTENT_NOTIFICATION, true)
                }.commit()
                PortalSessionStore.saveCookieHeader("SESSION=mock-session")
                NotificationManagerCompat.from(context).cancelAll()
                PortalKeepAliveService.setEnabled(context, true)
            }
            ACTION_RUN_POLL -> {
                WorkManager.getInstance(context).enqueue(
                    OneTimeWorkRequestBuilder<PortalPollWorker>().build()
                )
            }
        }
    }

    companion object {
        const val ACTION_RUN_POLL = "cn.edu.cupk.portalreader.DEBUG_RUN_POLL"
        const val ACTION_PREPARE = "cn.edu.cupk.portalreader.DEBUG_PREPARE"
    }
}
