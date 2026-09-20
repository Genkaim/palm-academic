package cn.edu.cupk.portalreader

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

class PortalKeepAliveService : Service() {
    override fun onCreate() {
        super.onCreate()
        ensureChannel(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val preferences = PortalNotificationPreferences.preferences(this)
        if (!preferences.getBoolean(PortalNotificationPreferences.KEY_PERSISTENT_NOTIFICATION, false)) {
            stopSelf()
            return START_NOT_STICKY
        }

        val openApp = PendingIntent.getActivity(
            this,
            NOTIFICATION_ID,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("掌上教务后台监测运行中")
            .setContentText("正在保持课表、成绩和考试通知检测")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setContentIntent(openApp)
            .build()
        startForeground(NOTIFICATION_ID, notification)
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "academic_keep_alive"
        private const val NOTIFICATION_ID = 3100

        fun setEnabled(context: Context, enabled: Boolean): Boolean {
            val preferences = PortalNotificationPreferences.preferences(context)
            // The service reads this value as soon as it starts. Persist it synchronously so
            // startForegroundService cannot race an asynchronous SharedPreferences.apply().
            if (!preferences.edit()
                .putBoolean(PortalNotificationPreferences.KEY_PERSISTENT_NOTIFICATION, enabled)
                .commit()
            ) return false
            val succeeded = runCatching {
                if (enabled) {
                    ContextCompat.startForegroundService(
                        context,
                        Intent(context, PortalKeepAliveService::class.java)
                    )
                } else {
                    context.stopService(Intent(context, PortalKeepAliveService::class.java))
                }
            }.isSuccess
            if (!succeeded) {
                preferences.edit()
                    .putBoolean(PortalNotificationPreferences.KEY_PERSISTENT_NOTIFICATION, !enabled)
                    .commit()
            }
            return succeeded
        }

        /** Attempts to restore the service without changing the user's persisted preference. */
        fun restoreIfEnabled(context: Context): Boolean {
            val enabled = PortalNotificationPreferences.preferences(context)
                .getBoolean(PortalNotificationPreferences.KEY_PERSISTENT_NOTIFICATION, false)
            if (!enabled) return false
            return runCatching {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, PortalKeepAliveService::class.java)
                )
            }.isSuccess
        }

        fun ensureChannel(context: Context) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "后台保活状态",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "显示掌上教务后台通知检测的运行状态"
                setShowBadge(false)
            }
            context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }

        fun canShowNotification(context: Context): Boolean {
            ensureChannel(context)
            val manager = context.getSystemService(NotificationManager::class.java)
            val channelEnabled = manager.getNotificationChannel(CHANNEL_ID)?.importance !=
                NotificationManager.IMPORTANCE_NONE
            return NotificationManagerCompat.from(context).areNotificationsEnabled() && channelEnabled
        }
    }
}
