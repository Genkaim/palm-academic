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
import okhttp3.Headers
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
                summary = "登录 Cookie 不存在",
                technicalDetails = "PortalHttp.hasSessionCookie() 返回 false。",
                notificationTriggered = notified
            )
            return@withContext finish("登录已过期", Result.success())
        }
        runCatching {
            val school = SchoolAdapterRepository.load(applicationContext)
            val coursePage = get(school.monitor.coursePageUrl(school.baseUrl))
            if (coursePage.isAuthenticationFailure()) {
                val notified = notifyAuthenticationFailure(preferences)
                details += coursePage.toHistoryDetail("课表", "登录状态失效")
                details += authenticationDetail(notified, "课表页面返回登录页或未授权状态")
                return@withContext finish("登录已过期", Result.success())
            }
            if (!coursePage.isSuccessful()) {
                details += coursePage.toHistoryDetail("课表", "请求失败")
                error("课表页面请求失败：HTTP ${coursePage.code}")
            }

            val semesterId = school.monitor.extractSemesterId(coursePage.body) ?: run {
                details += coursePage.toHistoryDetail(
                    category = "课表",
                    summary = "未识别当前学期",
                    technicalDetails = "学校定义中的 semesterIdPatterns 未匹配页面内容。"
                )
                error("未识别当前学期")
            }
            val studentId = school.monitor.extractStudentId(
                coursePage.finalUrl + "\n" + coursePage.body
            ) ?: run {
                details += coursePage.toHistoryDetail(
                    category = "课表",
                    summary = "未识别学生 ID",
                    technicalDetails = "学校定义中的 studentIdPatterns 未匹配入口最终地址或页面内容。"
                )
                error("未识别学生 ID")
            }

            run {
                val courseData = get(
                    school.monitor.courseDataUrl(school.baseUrl, semesterId, studentId)
                )
                if (courseData.isAuthenticationFailure()) {
                    val notified = notifyAuthenticationFailure(preferences)
                    details += combinedCourseDetail(
                        coursePage, courseData, semesterId, "登录状态失效"
                    )
                    details += authenticationDetail(notified, "课表数据接口返回登录页或未授权状态")
                    return@withContext finish("登录已过期", Result.success())
                }
                if (!courseData.isSuccessful()) {
                    details += combinedCourseDetail(coursePage, courseData, semesterId, "请求失败")
                    error("课表数据请求失败：HTTP ${courseData.code}")
                }
                val coursePayload = courseData.body.trim()
                if (coursePayload.isBlank()) {
                    details += combinedCourseDetail(
                        coursePage,
                        courseData,
                        semesterId,
                        summary = "响应格式无法识别",
                        technicalDetails = "课表数据响应为空。"
                    )
                    error("课表接口返回了无法识别的数据")
                }
                details += updateCourseSnapshot(preferences, semesterId, coursePage, courseData)
            }

            val gradeData = get(
                school.monitor.gradeDataUrl(school.baseUrl, semesterId, studentId)
            )
            if (gradeData.isAuthenticationFailure()) {
                val notified = notifyAuthenticationFailure(preferences)
                details += gradeData.toHistoryDetail("成绩", "登录状态失效")
                details += authenticationDetail(notified, "成绩页面返回登录页或未授权状态")
                return@withContext finish("登录已过期", Result.success())
            }
            if (!gradeData.isSuccessful()) {
                details += gradeData.toHistoryDetail("成绩", "请求失败")
                error("成绩请求失败：HTTP ${gradeData.code}")
            }
            val parsedGrades = PortalSnapshot.parsedDataJson(gradeData.body, type = "grade")
            details += updateGradeSnapshot(preferences, gradeData, parsedGrades)

            val examData = get(
                school.monitor.examDataUrl(school.baseUrl, semesterId, studentId)
            )
            if (examData.isAuthenticationFailure()) {
                val notified = notifyAuthenticationFailure(preferences)
                details += examData.toHistoryDetail("考试", "登录状态失效")
                details += authenticationDetail(notified, "考试页面返回登录页或未授权状态")
                return@withContext finish("登录已过期", Result.success())
            }
            if (!examData.isSuccessful()) {
                details += examData.toHistoryDetail("考试", "请求失败")
                error("考试请求失败：HTTP ${examData.code}")
            }
            val parsedExams = PortalSnapshot.parsedDataJson(examData.body, type = "exam")
            val examRows = PortalSnapshot.tableRows(examData.body)
            if (examRows.isEmpty() && PortalSnapshot.visibleDocument(examData.body).isBlank()) {
                details += examData.toHistoryDetail(
                    category = "考试",
                    summary = "页面结构无法识别",
                    technicalDetails = "未解析到表格行或可见文本。",
                    parsedContent = parsedExams
                )
                error("考试安排页面结构无法识别")
            }
            details += updateExamSnapshot(
                preferences,
                examData,
                examRows,
                parsedExams
            )
            preferences.edit()
                .putBoolean(KEY_AUTH_FAILURE_NOTIFIED, false)
                .putLong("last_checked", System.currentTimeMillis())
                .apply()
            finish("检查完成", Result.success())
        }.getOrElse { error ->
            details += PortalPollHistoryDetail(
                category = "检查错误",
                summary = error.message ?: "未知错误",
                technicalDetails = error.stackTraceToString()
            )
            finish("检查失败", Result.retry())
        }
    }

    private data class ResponseData(
        val requestedUrl: String,
        val code: Int,
        val finalUrl: String,
        val body: String,
        val transportDetails: String
    ) {
        fun isSuccessful(): Boolean = code in 200..299

        fun isAuthenticationFailure(): Boolean =
            code == 401 || code == 403 || AuthRepository.isLoginPage(body, finalUrl)

        fun toHistoryDetail(
            category: String,
            summary: String,
            technicalDetails: String = "",
            parsedContent: String = PortalSnapshot.parsedDataJson(body, category)
        ) = PortalPollHistoryDetail(
            category = category,
            summary = summary,
            requestUrl = requestedUrl,
            finalUrl = finalUrl,
            responseCode = code,
            technicalDetails = listOf(transportDetails, technicalDetails)
                .filter { it.isNotBlank() }
                .joinToString("\n\n"),
            currentContent = parsedContent
        )
    }

    private fun get(url: String): ResponseData {
        val request = Request.Builder().url(url).header("Accept", "text/html,application/json").get().build()
        return try {
            PortalHttp.client.newCall(request).execute().use { response ->
                val body = response.body?.string().orEmpty()
                val redirectChain = generateSequence(response) { it.priorResponse }
                    .toList()
                    .asReversed()
                    .joinToString("\n") { item ->
                        "${item.code} ${item.request.method} ${item.request.url}"
                    }
                ResponseData(
                    requestedUrl = url,
                    code = response.code,
                    finalUrl = response.request.url.toString(),
                    body = body,
                    transportDetails = buildString {
                        appendLine("请求方法：${response.request.method}")
                        appendLine("协议：${response.protocol}")
                        appendLine("状态信息：${response.message.ifBlank { "（无）" }}")
                        appendLine("重定向链：")
                        appendLine(redirectChain.ifBlank { "（无）" })
                        appendLine("请求头（凭据已遮蔽）：")
                        appendLine(response.request.headers.forHistoryLog())
                        appendLine("响应头（凭据已遮蔽）：")
                        append(response.headers.forHistoryLog())
                    }
                )
            }
        } catch (error: java.io.IOException) {
            throw IllegalStateException("GET $url 失败：${error.message ?: error.javaClass.name}", error)
        }
    }

    private fun Headers.forHistoryLog(): String {
        if (size == 0) return "（无）"
        return (0 until size).joinToString("\n") { index ->
            val name = name(index)
            val hidden = name.lowercase() in SENSITIVE_HEADERS
            "$name: ${if (hidden) "[已遮蔽]" else value(index)}"
        }
    }

    private fun authenticationDetail(notified: Boolean, reason: String) = PortalPollHistoryDetail(
        category = "登录状态",
        summary = "登录已过期",
        notificationEnabled = true,
        notificationTriggered = notified,
        technicalDetails = "$reason。登录失效通知${if (notified) "已发送" else "未发送或此前已发送"}。"
    )

    private fun updateCourseSnapshot(
        preferences: android.content.SharedPreferences,
        semesterId: String,
        entryResponse: ResponseData,
        response: ResponseData
    ): PortalPollHistoryDetail {
        val courseBody = response.body
        val parsedCourse = PortalSnapshot.courseDataJson(courseBody, semesterId)
        val newHash = PortalSnapshot.stableHash(parsedCourse)
        val hasEntries = PortalSnapshot.hasCourseEntries(courseBody)
        val oldHash = preferences.getString("course_hash", null)
        val oldSemester = preferences.getString("course_semester_id", null)
        val oldContent = preferences.getString("course_parsed_json_v2", null)
            ?: preferences.getString("course_raw_v1", null)?.takeIf { value ->
                value.trim().startsWith('{') || value.trim().startsWith('[')
            }
        val changed = PortalPollLogic.courseChanged(oldHash, oldSemester, newHash, semesterId, hasEntries)
        preferences.edit()
            .putString("course_hash", newHash)
            .putString("course_semester_id", semesterId)
            .putBoolean("course_has_entries", hasEntries)
            .putString("course_parsed_json_v2", parsedCourse)
            .remove("course_raw_v1")
            .apply()
        val enabled = PortalNotificationPreferences.isEnabled(
            preferences,
            PortalNotificationPreferences.KEY_SCHEDULE
        )
        val notified = changed && enabled &&
            notify(3000, "课表变动", "检测到课表新增或课程安排发生变化，请及时查看。")
        return PortalPollHistoryDetail(
            category = "课表",
            summary = when {
                oldHash == null -> "已建立初始数据"
                changed -> "检测到变动"
                else -> "无变化"
            },
            changed = changed,
            notificationEnabled = enabled,
            notificationTriggered = notified,
            requestUrl = response.requestedUrl,
            finalUrl = response.finalUrl,
            responseCode = response.code,
            technicalDetails = buildString {
                appendLine("课表入口请求：${entryResponse.requestedUrl}")
                appendLine(entryResponse.transportDetails)
                appendLine()
                appendLine("课表数据请求：${response.requestedUrl}")
                appendLine(response.transportDetails)
                appendLine()
                appendLine("学期 ID：$semesterId")
                appendLine("上次学期 ID：${oldSemester ?: "（无）"}")
                appendLine("包含课程条目：$hasEntries")
                appendLine("上次 SHA-256：${oldHash ?: "（无）"}")
                append("本次 SHA-256：$newHash")
            },
            previousContent = oldContent.orEmpty(),
            currentContent = parsedCourse
        )
    }

    private fun combinedCourseDetail(
        entryResponse: ResponseData,
        dataResponse: ResponseData,
        semesterId: String,
        summary: String,
        technicalDetails: String = ""
    ) = PortalPollHistoryDetail(
        category = "课表",
        summary = summary,
        requestUrl = entryResponse.requestedUrl,
        finalUrl = dataResponse.finalUrl,
        responseCode = dataResponse.code,
        technicalDetails = buildString {
            appendLine("课表入口请求：${entryResponse.requestedUrl}")
            appendLine(entryResponse.transportDetails)
            appendLine()
            appendLine("课表数据请求：${dataResponse.requestedUrl}")
            appendLine(dataResponse.transportDetails)
            if (technicalDetails.isNotBlank()) {
                appendLine()
                append(technicalDetails)
            }
        },
        currentContent = PortalSnapshot.courseDataJson(dataResponse.body, semesterId)
    )

    private fun updateExamSnapshot(
        preferences: android.content.SharedPreferences,
        response: ResponseData,
        rows: Set<String>,
        parsedContent: String
    ): PortalPollHistoryDetail {
        val snapshot = rows.sorted().joinToString("\u001E").ifBlank { parsedContent }
        // v2 保存完整行而非前三列；使用新基线键避免升级后因快照格式变化误报。
        val previous = preferences.getString("exam_rows_v2", null)
        val previousContent = preferences.getString("exam_parsed_json_v2", null)
        preferences.edit()
            .putString("exam_rows_v2", snapshot)
            .putString("exam_parsed_json_v2", parsedContent)
            .remove("exam_raw_v1")
            .apply()
        val changed = PortalPollLogic.contentChanged(previous, snapshot)
        val enabled = PortalNotificationPreferences.isEnabled(
            preferences,
            PortalNotificationPreferences.KEY_EXAM
        )
        val notified = changed && enabled &&
            notify(3002, "考试变动", "检测到考试新增或已有考试安排发生变化，请及时查看。")
        return PortalPollHistoryDetail(
            category = "考试",
            summary = when {
                previous == null -> "已建立初始数据"
                changed -> "检测到变动"
                else -> "无变化"
            },
            changed = changed,
            notificationEnabled = enabled,
            notificationTriggered = notified,
            requestUrl = response.requestedUrl,
            finalUrl = response.finalUrl,
            responseCode = response.code,
            technicalDetails = buildString {
                appendLine(response.transportDetails)
                appendLine()
                appendLine("解析行数：${rows.size}")
                appendLine("上次 SHA-256：${previous?.let(PortalSnapshot::stableHash) ?: "（无）"}")
                append("本次 SHA-256：${PortalSnapshot.stableHash(snapshot)}")
            },
            previousContent = previousContent.orEmpty(),
            currentContent = parsedContent
        )
    }

    private fun updateGradeSnapshot(
        preferences: android.content.SharedPreferences,
        response: ResponseData,
        parsedContent: String
    ): PortalPollHistoryDetail {
        val newHash = PortalSnapshot.stableHash(parsedContent)
        val oldHash = preferences.getString("grade_hash", null)
        val oldContent = preferences.getString("grade_parsed_json_v2", null)
        preferences.edit()
            .putString("grade_hash", newHash)
            .putString("grade_parsed_json_v2", parsedContent)
            .remove("grade_raw_v1")
            .apply()
        val changed = PortalPollLogic.contentChanged(oldHash, newHash)
        val enabled = PortalNotificationPreferences.isEnabled(
            preferences,
            PortalNotificationPreferences.KEY_GRADE
        )
        val notified = enabled && changed &&
            notify(3004, "成绩变动", "检测到课程成绩新增或已有成绩发生变化，请及时查看。")
        return PortalPollHistoryDetail(
            category = "成绩",
            summary = when {
                oldHash == null -> "已建立初始数据"
                changed -> "检测到变动"
                else -> "无变化"
            },
            changed = changed,
            notificationEnabled = enabled,
            notificationTriggered = notified,
            requestUrl = response.requestedUrl,
            finalUrl = response.finalUrl,
            responseCode = response.code,
            technicalDetails = buildString {
                appendLine(response.transportDetails)
                appendLine()
                appendLine("上次 SHA-256：${oldHash ?: "（无）"}")
                append("本次 SHA-256：$newHash")
            },
            previousContent = oldContent.orEmpty(),
            currentContent = parsedContent
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
        private val SENSITIVE_HEADERS = setOf(
            "authorization",
            "cookie",
            "proxy-authorization",
            "set-cookie"
        )
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
