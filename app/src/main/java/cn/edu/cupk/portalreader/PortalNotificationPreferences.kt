package cn.edu.cupk.portalreader

import android.content.Context
import android.content.SharedPreferences

object PortalNotificationPreferences {
    const val KEY_SCHEDULE = "notify_schedule"
    const val KEY_GRADE = "notify_grade"
    const val KEY_EXAM = "notify_exam"
    const val KEY_PERSISTENT_NOTIFICATION = "keep_alive_notification"

    private const val KEY_NEW_SCHEDULE_LEGACY = "notify_new_schedule"
    private const val KEY_GRADE_PUBLISHED_LEGACY = "notify_grade_published"
    private const val KEY_SCHEDULE_CHANGED_LEGACY = "notify_schedule_changed"
    private const val KEY_NEW_EXAM_LEGACY = "notify_new_exam"
    private const val KEY_THREE_CATEGORY_MIGRATED = "notification_categories_v2"

    val notificationKeys = listOf(
        KEY_SCHEDULE,
        KEY_GRADE,
        KEY_EXAM
    )

    fun preferences(context: Context): SharedPreferences {
        val preferences = context.getSharedPreferences(PortalPollWorker.PREFS, Context.MODE_PRIVATE)
        migrateLegacyCategories(preferences)
        return preferences
    }

    fun isEnabled(preferences: SharedPreferences, key: String): Boolean =
        if (preferences.contains(key)) preferences.getBoolean(key, true)
        else preferences.getBoolean("enabled", true)

    fun anyEnabled(preferences: SharedPreferences): Boolean =
        notificationKeys.any { isEnabled(preferences, it) }

    fun enabledCount(preferences: SharedPreferences): Int =
        notificationKeys.count { isEnabled(preferences, it) }

    fun clearSnapshots(context: Context) {
        preferences(context).edit()
            .remove("course_hash")
            .remove("course_semester_id")
            .remove("course_has_entries")
            .remove("grade_hash")
            .remove("exam_rows")
            .remove("exam_rows_v2")
            .putBoolean(PortalPollWorker.KEY_AUTH_FAILURE_NOTIFIED, false)
            .commit()
    }

    private fun migrateLegacyCategories(preferences: SharedPreferences) {
        if (preferences.getBoolean(KEY_THREE_CATEGORY_MIGRATED, false)) return
        val defaultEnabled = preferences.getBoolean("enabled", true)
        val hasLegacyScheduleSetting = preferences.contains(KEY_NEW_SCHEDULE_LEGACY) ||
            preferences.contains(KEY_SCHEDULE_CHANGED_LEGACY)
        val scheduleEnabled = if (hasLegacyScheduleSetting) {
            preferences.contains(KEY_NEW_SCHEDULE_LEGACY) &&
                preferences.getBoolean(KEY_NEW_SCHEDULE_LEGACY, false) ||
                preferences.contains(KEY_SCHEDULE_CHANGED_LEGACY) &&
                preferences.getBoolean(KEY_SCHEDULE_CHANGED_LEGACY, false)
        } else defaultEnabled
        val gradeEnabled = preferences.getBoolean(KEY_GRADE_PUBLISHED_LEGACY, defaultEnabled)
        val examEnabled = preferences.getBoolean(KEY_NEW_EXAM_LEGACY, defaultEnabled)
        preferences.edit()
            .putBoolean(KEY_SCHEDULE, scheduleEnabled)
            .putBoolean(KEY_GRADE, gradeEnabled)
            .putBoolean(KEY_EXAM, examEnabled)
            .putBoolean(KEY_THREE_CATEGORY_MIGRATED, true)
            .remove(KEY_NEW_SCHEDULE_LEGACY)
            .remove(KEY_GRADE_PUBLISHED_LEGACY)
            .remove(KEY_SCHEDULE_CHANGED_LEGACY)
            .remove(KEY_NEW_EXAM_LEGACY)
            .commit()
    }
}
