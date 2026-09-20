package cn.edu.cupk.portalreader

import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat

data class BackgroundSupportState(
    val bootReceiverAvailable: Boolean,
    val batteryOptimizationIgnored: Boolean,
    val backgroundRestricted: Boolean,
    val notificationsEnabled: Boolean
)

object BackgroundSupport {
    fun inspect(context: Context): BackgroundSupportState {
        val bootState = context.packageManager.getComponentEnabledSetting(
            ComponentName(context, PortalBootReceiver::class.java)
        )
        val powerManager = context.getSystemService(PowerManager::class.java)
        val activityManager = context.getSystemService(ActivityManager::class.java)
        return BackgroundSupportState(
            // Android exposes our receiver state, but OEM auto-start permission itself has no
            // reliable public read API. Never report it as enabled based on the receiver alone.
            bootReceiverAvailable = bootState != android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            batteryOptimizationIgnored = powerManager.isIgnoringBatteryOptimizations(context.packageName),
            backgroundRestricted = Build.VERSION.SDK_INT >= 28 && activityManager.isBackgroundRestricted,
            notificationsEnabled = NotificationManagerCompat.from(context).areNotificationsEnabled()
        )
    }

    fun openAutoStartSettings(context: Context) {
        val candidates = when (Build.MANUFACTURER.lowercase()) {
            "xiaomi", "redmi" -> listOf(
                ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity")
            )
            "huawei", "honor" -> listOf(
                ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
                ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity")
            )
            "oppo", "realme", "oneplus" -> listOf(
                ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
                ComponentName("com.oplus.safecenter", "com.oplus.safecenter.permission.startup.StartupAppListActivity")
            )
            "vivo", "iqoo" -> listOf(
                ComponentName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity")
            )
            else -> emptyList()
        }
        val opened = candidates.any { component ->
            runCatching {
                context.startActivity(Intent().setComponent(component).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }.isSuccess
        }
        if (!opened) openAppDetails(context)
    }

    fun openBatterySettings(context: Context) {
        val packageUri = Uri.parse("package:${context.packageName}")
        val direct = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, packageUri)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (runCatching { context.startActivity(direct) }.isFailure) {
            context.startActivity(
                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
    }

    fun openNotificationSettings(context: Context) {
        context.startActivity(
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }

    fun openAppDetails(context: Context) {
        context.startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }
}
