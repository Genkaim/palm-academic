package cn.edu.cupk.portalreader

import android.Manifest
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.core.app.NotificationManagerCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Outcome of one portal poll pass. The history entry has already been appended by the time this
 * is returned; the status text is the same string written into it and is what callers surface
 * (a Toast for the manual "立即检查" action, a Result for WorkManager).
 */
internal data class PollRunResult(
    /** False when the pass never started (monitor switch off, no categories enabled). */
    val started: Boolean,
    val status: String,
    /** WorkManager should retry later -- used for network/transient failures. */
    val shouldRetry: Boolean,
    val triggeredNotification: Boolean
)

/**
 * The actual change-detection pass, independent of how it was triggered: WorkManager schedules
 * [PortalPollWorker], and the notification settings screen runs the same engine for "立即检查".
 */
internal class PortalPollEngine(private val appContext: Context) {

    suspend fun run(manual: Boolean = false): PollRunResult = withContext(Dispatchers.IO) {
        val preferences = PortalNotificationPreferences.preferences(appContext)
        if (!manual && !preferences.getBoolean(PortalPollWorker.KEY_MONITOR_ENABLED, false)) {
            return@withContext PollRunResult(started = false, status = "后台检查未开启", shouldRetry = false, triggeredNotification = false)
        }
        if (!PortalNotificationPreferences.anyEnabled(preferences)) {
            return@withContext PollRunResult(started = false, status = "未开启任何变动提醒", shouldRetry = false, triggeredNotification = false)
        }
        val checkedAt = System.currentTimeMillis()
        val details = mutableListOf<PortalPollHistoryDetail>()
        var triggered = false
        fun finish(status: String, retry: Boolean = false): PollRunResult {
            triggered = details.any { it.notificationTriggered }
            PortalPollHistory.append(
                appContext,
                PortalPollHistoryEntry(
                    timestamp = checkedAt,
                    status = status,
                    notificationTriggered = triggered,
                    details = details.toList()
                )
            )
            return PollRunResult(started = true, status = status, shouldRetry = retry, triggeredNotification = triggered)
        }
        suspend fun prepareSilentPasswordRetry(reason: String): Boolean {
            if (!usesSilentPasswordReauthentication()) return false
            val renewed = attemptSilentPasswordReauthentication()
            details += PortalPollHistoryDetail(
                category = "登录状态",
                summary = if (renewed) "已静默恢复密码登录" else "正在静默重试密码登录",
                technicalDetails = "$reason；将在下一次检查中使用更新后的会话。"
            )
            return true
        }
        if (!PortalHttp.hasSessionCookie()) {
            if (usesSilentPasswordReauthentication()) {
                if (attemptSilentPasswordReauthentication()) {
                    // Continue this same comparison pass with the renewed cookie jar.
                } else {
                    details += PortalPollHistoryDetail(
                        category = "登录状态",
                        summary = "正在静默重试密码登录",
                        technicalDetails = "无验证码密码登录未完成，将由后台任务继续重试。"
                    )
                    return@withContext finish("正在重新登录", retry = true)
                }
            } else {
            val notified = notifyAuthenticationFailure(preferences)
            details += PortalPollHistoryDetail(
                category = "登录状态",
                summary = "登录 Cookie 不存在",
                technicalDetails = "PortalHttp.hasSessionCookie() 返回 false。",
                notificationTriggered = notified
            )
            return@withContext finish("登录已过期")
            }
        }
        runCatching {
            val school = SchoolAdapterRepository.load(appContext)
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
                if (prepareSilentPasswordRetry("课表页面返回登录页或未授权状态")) {
                    details += coursePage.toHistoryDetail("课表", "登录状态失效")
                    return@withContext finish("正在重新登录", retry = true)
                }
                val notified = notifyAuthenticationFailure(preferences)
                details += coursePage.toHistoryDetail("课表", "登录状态失效")
                details += authenticationDetail(notified, "课表页面返回登录页或未授权状态")
                return@withContext finish("登录已过期")
            }
            if (!coursePage.isSuccessful()) {
                details += coursePage.toHistoryDetail("课表", "请求失败")
                return@withContext finish("检查完成（入口暂不可用）")
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
                return@withContext finish("检查完成（规则未匹配）")
            }
            if (studentRequired && studentId == null) {
                details += coursePage.toHistoryDetail(
                    category = "课表",
                    summary = "未识别学生 ID",
                    technicalDetails = "学校规则与通用学号规则均未匹配入口最终地址或页面内容。"
                )
                return@withContext finish("检查完成（规则未匹配）")
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
                    if (prepareSilentPasswordRetry("课表数据接口返回登录页或未授权状态")) {
                        details += combinedCourseDetail(courseData, "登录状态失效")
                        return@withContext finish("正在重新登录", retry = true)
                    }
                    val notified = notifyAuthenticationFailure(preferences)
                    details += combinedCourseDetail(
                        courseData, "登录状态失效"
                    )
                    details += authenticationDetail(notified, "课表数据接口返回登录页或未授权状态")
                    return@withContext finish("登录已过期")
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
                    if (prepareSilentPasswordRetry("成绩页面返回登录页或未授权状态")) {
                        details += gradeData.toHistoryDetail("成绩", "登录状态失效")
                        return@withContext finish("正在重新登录", retry = true)
                    }
                    val notified = notifyAuthenticationFailure(preferences)
                    details += gradeData.toHistoryDetail("成绩", "登录状态失效")
                    details += authenticationDetail(notified, "成绩页面返回登录页或未授权状态")
                    return@withContext finish("登录已过期")
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
                    if (prepareSilentPasswordRetry("考试页面返回登录页或未授权状态")) {
                        details += examData.toHistoryDetail("考试", "登录状态失效")
                        return@withContext finish("正在重新登录", retry = true)
                    }
                    val notified = notifyAuthenticationFailure(preferences)
                    details += examData.toHistoryDetail("考试", "登录状态失效")
                    details += authenticationDetail(notified, "考试页面返回登录页或未授权状态")
                    return@withContext finish("登录已过期")
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
                .putBoolean(PortalPollWorker.KEY_AUTH_FAILURE_NOTIFIED, false)
                .putLong("last_checked", System.currentTimeMillis())
                .apply()
            finish(
                if (partiallyUnavailable) "检查完成（部分项目不可用）" else "检查完成"
            )
        }.getOrElse { error ->
            details += PortalPollHistoryDetail(
                category = "检查错误",
                summary = error.message ?: "未知错误"
            )
            val networkFailure = generateSequence<Throwable>(error) { it.cause }
                .any { it is java.io.IOException }
            finish(if (networkFailure) "网络检查失败" else "检查失败", retry = true)
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
        val renderedSnapshot = MaterialPageCache.loadRaw(appContext, item.url)
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
        val auth = runCatching { SchoolAdapterRepository.load(appContext).auth }.getOrNull()
        if (auth == null || auth.webOnly || !auth.captcha.required) return false
        if (preferences.getBoolean(PortalPollWorker.KEY_AUTH_FAILURE_NOTIFIED, false)) return false
        preferences.edit()
            .putBoolean(PortalPollWorker.KEY_CAPTCHA_REAUTH_REQUIRED, true)
            .apply()
        if (notify(3003, "教务登录已过期", "请打开掌上教务，输入验证码后重新登录。")) {
            preferences.edit().putBoolean(PortalPollWorker.KEY_AUTH_FAILURE_NOTIFIED, true).apply()
            return true
        }
        return false
    }

    private fun usesSilentPasswordReauthentication(): Boolean {
        val auth = runCatching { SchoolAdapterRepository.load(appContext).auth }.getOrNull() ?: return false
        return !auth.webOnly && !auth.captcha.required && PasswordCredentialStore.load(appContext) != null
    }

    private suspend fun attemptSilentPasswordReauthentication(): Boolean {
        val credential = PasswordCredentialStore.load(appContext) ?: return false
        return AuthRepository().login(credential.username, credential.password).isSuccess
    }

    private fun notify(id: Int, title: String, text: String): Boolean {
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(
                appContext, Manifest.permission.POST_NOTIFICATIONS
            ) != PackageManager.PERMISSION_GRANTED
        ) return false
        if (!NotificationManagerCompat.from(appContext).areNotificationsEnabled()) return false

        PortalPollWorker.ensureChannel(appContext)
        val intent = Intent(appContext, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(MainActivity.EXTRA_NOTIFICATION_ENTRY, true)
            if (id == 3003) putExtra(MainActivity.EXTRA_CAPTCHA_REAUTHENTICATION, true)
        }
        val pendingIntent = PendingIntent.getActivity(
            appContext, id, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(appContext, PortalPollWorker.CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()
        return runCatching {
            NotificationManagerCompat.from(appContext).notify(id, notification)
        }.isSuccess
    }
}
