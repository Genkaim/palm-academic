package cn.edu.cupk.portalreader

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.util.concurrent.TimeUnit

class PortalPollWorker(appContext: Context, params: WorkerParameters) :
    CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val preferences = PortalNotificationPreferences.preferences(applicationContext)
        if (!preferences.getBoolean(KEY_MONITOR_ENABLED, false)) return@withContext Result.success()
        if (!PortalNotificationPreferences.anyEnabled(preferences)) return@withContext Result.success()
        val checkedAt = System.currentTimeMillis()
        val details = mutableListOf<PortalPollHistoryDetail>()
        fun finish(status: String, result: Result): Result {
            PortalPollHistory.append(
                applicationContext,
                PortalPollHistoryEntry(
                    timestamp = checkedAt,
                    status = status,
                    notificationTriggered = details.any { it.notificationTriggered },
                    details = details.toList()
                )
            )
            return result
        }
        if (!PortalHttp.hasSessionCookie()) {
            val notified = notifyAuthenticationFailure(preferences)
            details += PortalPollHistoryDetail(
                category = "登录状态",
                summary = "登录已过期",
                notificationTriggered = notified
            )
            return@withContext finish("登录已过期", Result.success())
        }
        runCatching {
            val coursePage = get(PortalConfig.COURSE_TABLE)
            if (coursePage.isAuthenticationFailure()) {
                val notified = notifyAuthenticationFailure(preferences)
                details += PortalPollHistoryDetail("登录状态", "登录已过期", notificationTriggered = notified)
                return@withContext finish("登录已过期", Result.success())
            }

            val semesterId = Regex(
                "currentSemester\\s*=.*?[\"']?id[\"']?\\s*:\\s*(\\d+)",
                setOf(RegexOption.DOT_MATCHES_ALL)
            ).find(coursePage.body)?.groupValues?.getOrNull(1)
                ?: Regex("var\\s+semesterId\\s*=\\s*(\\d+)").find(coursePage.body)?.groupValues?.getOrNull(1)

            if (semesterId != null) {
                val courseData = get(
                    "${PortalConfig.COURSE_TABLE}/get-data" +
                        "?bizTypeId=2&semesterId=$semesterId&searchTeachingSyllabus=true"
                )
                if (courseData.isAuthenticationFailure()) {
                    val notified = notifyAuthenticationFailure(preferences)
                    details += PortalPollHistoryDetail("登录状态", "登录已过期", notificationTriggered = notified)
                    return@withContext finish("登录已过期", Result.success())
                }
                val coursePayload = courseData.body.trim()
                if (!coursePayload.startsWith('[') && !coursePayload.startsWith('{')) {
                    error("课表接口返回了无法识别的数据")
                }
                details += updateCourseSnapshot(preferences, semesterId, courseData.body)
            } else {
                details += PortalPollHistoryDetail("课表", "未识别当前学期")
            }

            val gradeData = get(PortalConfig.GRADE)
            if (gradeData.isAuthenticationFailure()) {
                val notified = notifyAuthenticationFailure(preferences)
                details += PortalPollHistoryDetail("登录状态", "登录已过期", notificationTriggered = notified)
                return@withContext finish("登录已过期", Result.success())
            }
            val visibleGrades = PortalSnapshot.visibleDocument(gradeData.body)
            if (visibleGrades.isNotBlank()) {
                details += compareAndNotify(
                    preferences = preferences,
                    key = "grade_hash",
                    previewKey = "grade_preview_v1",
                    newHash = PortalSnapshot.stableHash(visibleGrades),
                    newPreview = PortalPollHistory.preview(visibleGrades),
                    category = "成绩",
                    enabled = PortalNotificationPreferences.isEnabled(
                        preferences,
                        PortalNotificationPreferences.KEY_GRADE
                    ),
                    id = 3004,
                    title = "成绩变动",
                    text = "检测到课程成绩新增或已有成绩发生变化，请及时查看。"
                )
            } else {
                details += PortalPollHistoryDetail("成绩", "未识别到成绩内容")
            }

            val examData = get(PortalConfig.EXAM)
            if (examData.isAuthenticationFailure()) {
                val notified = notifyAuthenticationFailure(preferences)
                details += PortalPollHistoryDetail("登录状态", "登录已过期", notificationTriggered = notified)
                return@withContext finish("登录已过期", Result.success())
            }
            if (!PortalSnapshot.hasTable(examData.body, "exam-table")) {
                error("考试安排页面结构无法识别")
            }
            details += updateExamSnapshot(preferences, PortalSnapshot.tableRows(examData.body, "exam-table"))
            preferences.edit()
                .putBoolean(KEY_AUTH_FAILURE_NOTIFIED, false)
                .putLong("last_checked", System.currentTimeMillis())
                .apply()
            finish("检查完成", Result.success())
        }.getOrElse { error ->
            details += PortalPollHistoryDetail(
                category = "检查错误",
                summary = error.message ?: "未知错误"
            )
            finish("检查失败", Result.retry())
        }
    }

    private data class ResponseData(val code: Int, val finalUrl: String, val body: String) {
        fun isAuthenticationFailure(): Boolean =
            code == 401 || code == 403 || AuthRepository.isLoginPage(body, finalUrl)
    }

    private fun get(url: String): ResponseData {
        val request = Request.Builder().url(url).header("Accept", "text/html,application/json").get().build()
        return PortalHttp.client.newCall(request).execute().use { response ->
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful && response.code != 401 && response.code != 403) {
                error("HTTP ${response.code}")
            }
            ResponseData(response.code, response.request.url.toString(), body)
        }
    }

    private fun updateCourseSnapshot(
        preferences: android.content.SharedPreferences,
        semesterId: String,
        courseBody: String
    ): PortalPollHistoryDetail {
        val newHash = PortalSnapshot.stableHash(courseBody)
        val hasEntries = PortalSnapshot.hasCourseEntries(courseBody)
        val oldHash = preferences.getString("course_hash", null)
        val oldSemester = preferences.getString("course_semester_id", null)
        val oldPreview = preferences.getString("course_preview_v1", null)
        val newPreview = PortalPollHistory.preview(courseBody)
        val changed = PortalPollLogic.courseChanged(oldHash, oldSemester, newHash, semesterId, hasEntries)
        preferences.edit()
            .putString("course_hash", newHash)
            .putString("course_semester_id", semesterId)
            .putBoolean("course_has_entries", hasEntries)
            .putString("course_preview_v1", newPreview)
            .apply()
        val notified = changed && PortalNotificationPreferences.isEnabled(
                preferences,
                PortalNotificationPreferences.KEY_SCHEDULE
            ) && notify(3000, "课表变动", "检测到课表新增或课程安排发生变化，请及时查看。")
        return PortalPollHistoryDetail(
            category = "课表",
            summary = when {
                oldHash == null -> "已建立初始数据"
                changed -> "检测到变动"
                else -> "无变化"
            },
            changed = changed,
            notificationTriggered = notified,
            difference = if (changed) PortalPollHistory.difference(oldPreview, newPreview) else ""
        )
    }

    private fun updateExamSnapshot(
        preferences: android.content.SharedPreferences,
        rows: Set<String>
    ): PortalPollHistoryDetail {
        val snapshot = rows.sorted().joinToString("\u001E")
        // v2 保存完整行而非前三列；使用新基线键避免升级后因快照格式变化误报。
        val previous = preferences.getString("exam_rows_v2", null)
        preferences.edit().putString("exam_rows_v2", snapshot).apply()
        val changed = PortalPollLogic.contentChanged(previous, snapshot)
        val notified = changed && PortalNotificationPreferences.isEnabled(
                preferences,
                PortalNotificationPreferences.KEY_EXAM
            ) && notify(3002, "考试变动", "检测到考试新增或已有考试安排发生变化，请及时查看。")
        return PortalPollHistoryDetail(
            category = "考试",
            summary = when {
                previous == null -> "已建立初始数据"
                changed -> "检测到变动"
                else -> "无变化"
            },
            changed = changed,
            notificationTriggered = notified,
            difference = if (changed) PortalPollHistory.difference(
                previous?.let(PortalPollHistory::preview),
                PortalPollHistory.preview(snapshot)
            ) else ""
        )
    }

    private fun compareAndNotify(
        preferences: android.content.SharedPreferences,
        key: String,
        previewKey: String,
        newHash: String,
        newPreview: String,
        category: String,
        enabled: Boolean,
        id: Int,
        title: String,
        text: String
    ): PortalPollHistoryDetail {
        val oldHash = preferences.getString(key, null)
        val oldPreview = preferences.getString(previewKey, null)
        if (newHash.isBlank()) return PortalPollHistoryDetail(category, "未识别到有效数据")
        preferences.edit().putString(key, newHash).putString(previewKey, newPreview).apply()
        val changed = PortalPollLogic.contentChanged(oldHash, newHash)
        val notified = enabled && changed && notify(id, title, text)
        return PortalPollHistoryDetail(
            category = category,
            summary = when {
                oldHash == null -> "已建立初始数据"
                changed -> "检测到变动"
                else -> "无变化"
            },
            changed = changed,
            notificationTriggered = notified,
            difference = if (changed) PortalPollHistory.difference(oldPreview, newPreview) else ""
        )
    }

    private fun notifyAuthenticationFailure(preferences: android.content.SharedPreferences): Boolean {
        if (preferences.getBoolean(KEY_AUTH_FAILURE_NOTIFIED, false)) return false
        if (notify(3003, "教务登录已过期", "请打开掌上教务重新登录，以继续后台通知检测。")) {
            preferences.edit().putBoolean(KEY_AUTH_FAILURE_NOTIFIED, true).apply()
            return true
        }
        return false
    }

    private fun notify(id: Int, title: String, text: String): Boolean {
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(
                applicationContext, Manifest.permission.POST_NOTIFICATIONS
            ) != PackageManager.PERMISSION_GRANTED
        ) return false
        if (!NotificationManagerCompat.from(applicationContext).areNotificationsEnabled()) return false

        ensureChannel(applicationContext)
        val intent = Intent(applicationContext, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            applicationContext, id, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()
        return runCatching {
            NotificationManagerCompat.from(applicationContext).notify(id, notification)
        }.isSuccess
    }

    companion object {
        const val PREFS = "portal_monitor"
        const val CHANNEL_ID = "academic_changes"
        internal const val KEY_MONITOR_ENABLED = "enabled"
        internal const val KEY_AUTH_FAILURE_NOTIFIED = "auth_failure_notified"

        fun ensureChannel(context: Context) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "教务信息提醒",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply { description = "课表、成绩和考试的新增与变动提醒" }
            context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }

    }
}

object PortalMonitor {
    private const val WORK_NAME = "portal_course_exam_poll"

    fun schedule(context: Context, minutes: Long) {
        PortalPollWorker.ensureChannel(context)
        val interval = minutes.coerceAtLeast(15)
        enqueuePolling(context, interval)
        val preferences = PortalNotificationPreferences.preferences(context)
        preferences.edit().putBoolean(PortalPollWorker.KEY_MONITOR_ENABLED, true).putLong("interval", interval).apply()
    }

    fun reconcile(context: Context) {
        val preferences = PortalNotificationPreferences.preferences(context)
        if (PortalNotificationPreferences.anyEnabled(preferences)) {
            schedule(context, preferences.getLong("interval", 30L))
        } else {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
            preferences.edit().putBoolean(PortalPollWorker.KEY_MONITOR_ENABLED, false).apply()
        }
        restoreKeepAlive(context, preferences)
    }

    /** Restores persisted background state after process start, app update, or device boot. */
    fun restore(context: Context) {
        val preferences = PortalNotificationPreferences.preferences(context)
        if (
            preferences.getBoolean(PortalPollWorker.KEY_MONITOR_ENABLED, false) &&
            PortalNotificationPreferences.anyEnabled(preferences)
        ) {
            schedule(context, preferences.getLong("interval", 30L))
        } else {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
        }
        restoreKeepAlive(context, preferences)
    }

    private fun restoreKeepAlive(context: Context, preferences: android.content.SharedPreferences) {
        if (preferences.getBoolean(PortalNotificationPreferences.KEY_PERSISTENT_NOTIFICATION, false)) {
            PortalKeepAliveService.restoreIfEnabled(context)
        }
    }

    private fun enqueuePolling(context: Context, interval: Long) {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()
        val request = PeriodicWorkRequestBuilder<PortalPollWorker>(interval, TimeUnit.MINUTES)
            .setConstraints(constraints)
            .build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            WORK_NAME,
            ExistingPeriodicWorkPolicy.UPDATE,
            request
        )
    }

    fun cancel(context: Context) {
        WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
        PortalKeepAliveService.setEnabled(context, false)
        PortalNotificationPreferences.preferences(context).edit()
            .putBoolean(PortalPollWorker.KEY_MONITOR_ENABLED, false)
            .apply()
    }
}
