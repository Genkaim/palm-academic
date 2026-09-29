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
                summary = "登录 Cookie 不存在",
                technicalDetails = "PortalHttp.hasSessionCookie() 返回 false。",
                notificationTriggered = notified
            )
            return@withContext finish("登录已过期", Result.success())
        }
        runCatching {
            val school = SchoolAdapterRepository.load(applicationContext)
            val scheduleEnabled = PortalNotificationPreferences.isEnabled(
                preferences,
                PortalNotificationPreferences.KEY_SCHEDULE
            )
            val gradeEnabled = PortalNotificationPreferences.isEnabled(
                preferences,
                PortalNotificationPreferences.KEY_GRADE
            )
            val examEnabled = PortalNotificationPreferences.isEnabled(
                preferences,
                PortalNotificationPreferences.KEY_EXAM
            )
            val coursePage = get(school.monitor.coursePageUrl(school.baseUrl))
            if (coursePage.isAuthenticationFailure()) {
                val notified = notifyAuthenticationFailure(preferences)
                details += coursePage.toHistoryDetail("课表", "登录状态失效")
                details += authenticationDetail(notified, "课表页面返回登录页或未授权状态")
                return@withContext finish("登录已过期", Result.success())
            }
            if (!coursePage.isSuccessful()) {
                details += coursePage.toHistoryDetail("课表", "请求失败")
                return@withContext finish("检查完成（入口暂不可用）", Result.success())
            }

            val semesterId = school.monitor.extractSemesterId(coursePage.body)
            val studentId = school.monitor.extractStudentId(
                coursePage.finalUrl + "\n" + coursePage.body
            )
            val semesterRequired = school.monitor.requiresSemesterId(
                scheduleEnabled,
                gradeEnabled,
                examEnabled
            )
            val studentRequired = school.monitor.requiresStudentId(
                scheduleEnabled,
                gradeEnabled,
                examEnabled
            )
            if (semesterRequired && semesterId == null) {
                details += coursePage.toHistoryDetail(
                    category = "课表",
                    summary = "未识别当前学期",
                    technicalDetails = "学校定义中的 semesterIdPatterns 未匹配页面内容。"
                )
                return@withContext finish("检查完成（规则未匹配）", Result.success())
            }
            if (studentRequired && studentId == null) {
                details += coursePage.toHistoryDetail(
                    category = "课表",
                    summary = "未识别学生 ID",
                    technicalDetails = "学校规则与通用学号规则均未匹配入口最终地址或页面内容。"
                )
                return@withContext finish("检查完成（规则未匹配）", Result.success())
            }
            val resolvedSemesterId = semesterId.orEmpty()
            val resolvedStudentId = studentId.orEmpty()
            var partiallyUnavailable = false

            if (scheduleEnabled) {
                val courseData = get(
                    school.monitor.courseDataUrl(
                        school.baseUrl,
                        resolvedSemesterId,
                        resolvedStudentId
                    ),
                    referer = coursePage.finalUrl,
                    ajax = true
                )
                if (courseData.isAuthenticationFailure()) {
                    val notified = notifyAuthenticationFailure(preferences)
                    details += combinedCourseDetail(
                        courseData, "登录状态失效"
                    )
                    details += authenticationDetail(notified, "课表数据接口返回登录页或未授权状态")
                    return@withContext finish("登录已过期", Result.success())
                }
                if (!courseData.isSuccessful()) {
                    details += combinedCourseDetail(
                        courseData, "请求失败"
                    )
                    partiallyUnavailable = true
                } else if (courseData.body.isBlank()) {
                    details += combinedCourseDetail(
                        courseData,
                        summary = "响应格式无法识别",
                        technicalDetails = "课表数据响应为空。"
                    )
                    partiallyUnavailable = true
                } else {
                    val renderedCourse = renderedSnapshotOrResponse(
                        school = school,
                        nativeType = "schedule",
                        responseBody = courseData.body
                    )
                    details += updateCourseSnapshot(
                        preferences,
                        resolvedSemesterId,
                        courseData,
                        renderedCourse
                    )
                }
            }

            if (gradeEnabled) {
                val gradeData = getNativePage(
                    school = school,
                    nativeType = "grade",
                    dataUrl = school.monitor.gradeDataUrl(
                        school.baseUrl,
                        resolvedSemesterId,
                        resolvedStudentId
                    ),
                    initialReferer = coursePage.finalUrl
                )
                if (gradeData.isAuthenticationFailure()) {
                    val notified = notifyAuthenticationFailure(preferences)
                    details += gradeData.toHistoryDetail("成绩", "登录状态失效")
                    details += authenticationDetail(notified, "成绩页面返回登录页或未授权状态")
                    return@withContext finish("登录已过期", Result.success())
                }
                if (!gradeData.isSuccessful()) {
                    details += gradeData.toHistoryDetail("成绩", "请求失败")
                    partiallyUnavailable = true
                } else {
                    val parsedGrades = renderedSnapshotOrResponse(
                        school = school,
                        nativeType = "grade",
                        responseBody = gradeData.body
                    )
                    details += updateGradeSnapshot(preferences, gradeData, parsedGrades)
                }
            }

            if (examEnabled) {
                val examData = getNativePage(
                    school = school,
                    nativeType = "exam",
                    dataUrl = school.monitor.examDataUrl(
                        school.baseUrl,
                        resolvedSemesterId,
                        resolvedStudentId
                    ),
                    initialReferer = coursePage.finalUrl
                )
                if (examData.isAuthenticationFailure()) {
                    val notified = notifyAuthenticationFailure(preferences)
                    details += examData.toHistoryDetail("考试", "登录状态失效")
                    details += authenticationDetail(notified, "考试页面返回登录页或未授权状态")
                    return@withContext finish("登录已过期", Result.success())
                }
                if (!examData.isSuccessful()) {
                    details += examData.toHistoryDetail("考试", "请求失败")
                    partiallyUnavailable = true
                } else {
                    val parsedExams = renderedSnapshotOrResponse(
                        school = school,
                        nativeType = "exam",
                        responseBody = examData.body
                    )
                    val examRows = PortalSnapshot.tableRows(examData.body)
                    if (
                        examRows.isEmpty() &&
                        PortalSnapshot.visibleDocument(examData.body).isBlank() &&
                        !PortalSnapshot.materialPageHasData(parsedExams, "exam")
                    ) {
                        details += examData.toHistoryDetail(
                            category = "考试",
                            summary = "未识别到考试内容",
                            technicalDetails = "响应为空，未更新考试基线。"
                        )
                        partiallyUnavailable = true
                    } else {
                        details += updateExamSnapshot(
                            preferences,
                            examData,
                            examRows,
                            parsedExams
                        )
                    }
                }
            }
            preferences.edit()
                .putBoolean(KEY_AUTH_FAILURE_NOTIFIED, false)
                .putLong("last_checked", System.currentTimeMillis())
                .apply()
            finish(
                if (partiallyUnavailable) "检查完成（部分项目不可用）" else "检查完成",
                Result.success()
            )
        }.getOrElse { error ->
            details += PortalPollHistoryDetail(
                category = "检查错误",
                summary = error.message ?: "未知错误"
            )
            val networkFailure = generateSequence<Throwable>(error) { it.cause }
                .any { it is java.io.IOException }
            finish(if (networkFailure) "网络检查失败" else "检查失败", Result.retry())
        }
    }

    private data class ResponseData(
        val code: Int,
        val finalUrl: String,
        val body: String
    ) {
        fun isSuccessful(): Boolean = code in 200..299

        fun isAuthenticationFailure(): Boolean =
            code == 401 || code == 403 || AuthRepository.isLoginPage(body, finalUrl)

        fun toHistoryDetail(
            category: String,
            summary: String,
            technicalDetails: String = ""
        ) = PortalPollHistoryDetail(
            category = category,
            summary = summary,
            responseCode = code,
            technicalDetails = technicalDetails
        )
    }

    private fun get(url: String, referer: String? = null, ajax: Boolean = false): ResponseData {
        val request = portalReadRequest(url, referer, ajax)
        return try {
            PortalHttp.client.newCall(request).execute().use { response ->
                val body = response.body?.string().orEmpty()
                ResponseData(
                    code = response.code,
                    finalUrl = response.request.url.toString(),
                    body = body
                )
            }
        } catch (error: java.io.IOException) {
            throw IllegalStateException("GET $url 失败：${error.message ?: error.javaClass.name}", error)
        }
    }

    /**
     * EAMS establishes controller state when the user enters the grade/exam feature. Opening an
     * /info/{studentId} URL directly can therefore return a 500 even with a valid session. Follow
     * the same entry-page path as the interactive UI before requesting a separate data URL.
     */
    private fun getNativePage(
        school: SchoolDefinition,
        nativeType: String,
        dataUrl: String,
        initialReferer: String
    ): ResponseData {
        val entryUrl = school.quickItems.firstOrNull { it.nativeType == nativeType }?.url
            ?: return get(dataUrl, referer = initialReferer)
        val entryResponse = get(entryUrl, referer = initialReferer)
        if (!entryResponse.isSuccessful() || entryResponse.isAuthenticationFailure()) {
            return entryResponse
        }
        if (canonicalUrl(entryResponse.finalUrl) == canonicalUrl(dataUrl)) {
            return entryResponse
        }
        return get(dataUrl, referer = entryResponse.finalUrl)
    }

    private fun canonicalUrl(value: String): String = value.substringBefore('#').trimEnd('/')

    /**
     * Grade and exam pages populate their tables after JavaScript runs. A successful HTTP GET
     * can therefore contain only the empty table shell even though the feature renders normally.
     * Prefer the adapter's latest populated publication in that case so history and comparisons
     * contain the actual cards/fields the user saw instead of an empty JSON structure.
     */
    private fun renderedSnapshotOrResponse(
        school: SchoolDefinition,
        nativeType: String,
        responseBody: String
    ): String {
        val responseSnapshot = PortalSnapshot.parsedDataJson(responseBody, type = nativeType)
        if (PortalSnapshot.parsedHtmlHasRows(responseBody)) return responseSnapshot
        val item = school.quickItems.firstOrNull { it.nativeType == nativeType }
            ?: return responseSnapshot
        val renderedSnapshot = MaterialPageCache.loadRaw(applicationContext, item.url)
            ?: return responseSnapshot
        return renderedSnapshot.takeIf {
            PortalSnapshot.materialPageHasData(it, nativeType)
        }?.let(PortalSnapshot::historyDisplayContent) ?: responseSnapshot
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
        response: ResponseData,
        renderedContent: String
    ): PortalPollHistoryDetail {
        val courseBody = response.body
        val parsedCourse = PortalSnapshot.courseDataJson(courseBody, semesterId)
        val currentRows = PortalLogDetails.courseRows(courseBody).ifEmpty {
            PortalLogDetails.materialRows(renderedContent, "schedule")
        }
        val newSnapshot = currentRows.takeIf(List<String>::isNotEmpty)
            ?.let(PortalLogDetails::encode)
            ?: "fallback:${PortalSnapshot.stableHash(parsedCourse)}"
        val hasEntries = PortalSnapshot.hasCourseEntries(courseBody)
        val previousSnapshot = preferences.getString("course_business_snapshot_v1", null)
        val oldSemester = preferences.getString("course_business_semester_id_v1", null)
        val changed = PortalPollLogic.courseChanged(
            previousSnapshot,
            oldSemester,
            newSnapshot,
            semesterId,
            hasEntries
        )
        preferences.edit()
            .putString("course_business_snapshot_v1", newSnapshot)
            .putString("course_business_semester_id_v1", semesterId)
            .putBoolean("course_has_entries", hasEntries)
            .remove("course_hash")
            .remove("course_semester_id")
            .remove("course_semantic_hash_v3")
            .remove("course_semantic_semester_id_v3")
            .remove("course_parsed_json_v2")
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
                previousSnapshot == null -> "已建立初始数据"
                changed -> "检测到变动"
                else -> "无变化"
            },
            changed = changed,
            notificationEnabled = enabled,
            notificationTriggered = notified,
            responseCode = response.code,
            difference = PortalLogDetails.describe(
                previousSnapshot = previousSnapshot?.takeIf { it.startsWith('[') },
                currentRows = currentRows,
                changed = changed
            )
        )
    }

    private fun combinedCourseDetail(
        dataResponse: ResponseData,
        summary: String,
        technicalDetails: String = ""
    ) = PortalPollHistoryDetail(
        category = "课表",
        summary = summary,
        responseCode = dataResponse.code,
        technicalDetails = technicalDetails
    )

    private fun updateExamSnapshot(
        preferences: android.content.SharedPreferences,
        response: ResponseData,
        rows: Set<String>,
        parsedContent: String
    ): PortalPollHistoryDetail {
        val currentRows = PortalLogDetails.materialRows(parsedContent, "exam")
            .ifEmpty { rows.sorted() }
        val snapshot = currentRows.takeIf(List<String>::isNotEmpty)
            ?.let(PortalLogDetails::encode)
            ?: "fallback:${PortalSnapshot.stableHash(parsedContent)}"
        val previous = preferences.getString("exam_business_snapshot_v1", null)
        preferences.edit()
            .putString("exam_business_snapshot_v1", snapshot)
            .remove("exam_rows_v2")
            .remove("exam_parsed_json_v2")
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
            responseCode = response.code,
            difference = PortalLogDetails.describe(
                previousSnapshot = previous?.takeIf { it.startsWith('[') },
                currentRows = currentRows,
                changed = changed
            )
        )
    }

    private fun updateGradeSnapshot(
        preferences: android.content.SharedPreferences,
        response: ResponseData,
        parsedContent: String
    ): PortalPollHistoryDetail {
        val currentRows = PortalLogDetails.materialRows(parsedContent, "grade")
        val newSnapshot = currentRows.takeIf(List<String>::isNotEmpty)
            ?.let(PortalLogDetails::encode)
            ?: "fallback:${PortalSnapshot.stableHash(parsedContent)}"
        val previousSnapshot = preferences.getString("grade_business_snapshot_v1", null)
        preferences.edit()
            .putString("grade_business_snapshot_v1", newSnapshot)
            .remove("grade_hash")
            .remove("grade_parsed_json_v2")
            .remove("grade_raw_v1")
            .apply()
        val changed = PortalPollLogic.contentChanged(previousSnapshot, newSnapshot)
        val enabled = PortalNotificationPreferences.isEnabled(
            preferences,
            PortalNotificationPreferences.KEY_GRADE
        )
        val notified = enabled && changed &&
            notify(3004, "成绩变动", "检测到课程成绩新增或已有成绩发生变化，请及时查看。")
        return PortalPollHistoryDetail(
            category = "成绩",
            summary = when {
                previousSnapshot == null -> "已建立初始数据"
                changed -> "检测到变动"
                else -> "无变化"
            },
            changed = changed,
            notificationEnabled = enabled,
            notificationTriggered = notified,
            responseCode = response.code,
            difference = PortalLogDetails.describe(
                previousSnapshot = previousSnapshot?.takeIf { it.startsWith('[') },
                currentRows = currentRows,
                changed = changed
            )
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
            putExtra(MainActivity.EXTRA_NOTIFICATION_ENTRY, true)
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

private const val PORTAL_BROWSER_USER_AGENT =
    "Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

internal fun portalReadRequest(url: String, referer: String? = null, ajax: Boolean = false): Request =
    Request.Builder()
        .url(url)
        .header("User-Agent", PORTAL_BROWSER_USER_AGENT)
        .header(
            "Accept",
            if (ajax) "application/json,text/javascript,*/*;q=0.8"
            else "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8"
        )
        .header("Accept-Language", "zh-CN,zh;q=0.9")
        .apply {
            if (!referer.isNullOrBlank()) header("Referer", referer)
            if (ajax) header("X-Requested-With", "XMLHttpRequest")
        }
        .get()
        .build()

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
        PortalKeepAliveService.stopPreservingPreference(context)
        PortalNotificationPreferences.preferences(context).edit()
            .putBoolean(PortalPollWorker.KEY_MONITOR_ENABLED, false)
            .apply()
    }
}
