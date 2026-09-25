package cn.edu.cupk.portalreader

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

data class PortalPollHistoryDetail(
    val category: String,
    val summary: String,
    val changed: Boolean = false,
    val notificationEnabled: Boolean? = null,
    val notificationTriggered: Boolean = false,
    val requestUrl: String = "",
    val finalUrl: String = "",
    val responseCode: Int? = null,
    val technicalDetails: String = "",
    val previousContent: String = "",
    val currentContent: String = "",
    // Kept for records written by v0.3.2 and earlier.
    val difference: String = ""
)

data class PortalPollHistoryEntry(
    val timestamp: Long,
    val status: String,
    val notificationTriggered: Boolean,
    val details: List<PortalPollHistoryDetail>
)

data class PortalHomeChangeNotice(
    val timestamp: Long,
    val category: String,
    val nativeType: String
)

object PortalPollHistory {
    private const val FILE_NAME = "portal_poll_history.json"
    private const val HOME_NOTICE_PREFERENCES = "portal_home_change_notices"
    private val lock = Any()
    private val _version = MutableStateFlow(0L)
    val version = _version.asStateFlow()

    fun read(context: Context): List<PortalPollHistoryEntry> = synchronized(lock) {
        readUnlocked(context)
    }

    fun append(context: Context, entry: PortalPollHistoryEntry) = synchronized(lock) {
        val entries = listOf(entry) + readUnlocked(context)
        writeUnlocked(context, entries)
        notifyChanged()
    }

    fun clear(context: Context) = synchronized(lock) {
        historyFile(context).delete()
        notifyChanged()
    }

    fun latestUnreadChange(context: Context): PortalHomeChangeNotice? {
        val acknowledged = context.applicationContext.getSharedPreferences(
            HOME_NOTICE_PREFERENCES,
            Context.MODE_PRIVATE
        )
        return latestUnreadPortalChange(read(context)) { nativeType ->
            acknowledged.getLong("read_$nativeType", 0L)
        }
    }

    fun acknowledgeHomeChange(context: Context, notice: PortalHomeChangeNotice) {
        context.applicationContext.getSharedPreferences(
            HOME_NOTICE_PREFERENCES,
            Context.MODE_PRIVATE
        ).edit().putLong("read_${notice.nativeType}", notice.timestamp).apply()
        notifyChanged()
    }

    private fun notifyChanged() {
        _version.value = _version.value + 1L
    }

    private fun readUnlocked(context: Context): List<PortalPollHistoryEntry> = runCatching {
        val file = historyFile(context)
        if (!file.isFile) return@runCatching emptyList()
        val array = JSONArray(file.readText())
        (0 until array.length()).map { index -> array.getJSONObject(index).toEntry() }
    }.getOrDefault(emptyList())

    private fun writeUnlocked(context: Context, entries: List<PortalPollHistoryEntry>) {
        runCatching {
            val target = historyFile(context)
            val temporary = File(target.parentFile, "$FILE_NAME.tmp")
            temporary.writeText(JSONArray().apply { entries.forEach { put(it.toJson()) } }.toString())
            if (!temporary.renameTo(target)) {
                target.writeText(temporary.readText())
                temporary.delete()
            }
        }
    }

    private fun historyFile(context: Context) = File(context.filesDir, FILE_NAME)

    private fun PortalPollHistoryEntry.toJson() = JSONObject().apply {
        put("timestamp", timestamp)
        put("status", status)
        put("notificationTriggered", notificationTriggered)
        put("details", JSONArray().apply {
            details.forEach { detail ->
                put(JSONObject().apply {
                    put("category", detail.category)
                    put("summary", detail.summary)
                    put("changed", detail.changed)
                    detail.notificationEnabled?.let { put("notificationEnabled", it) }
                    put("notificationTriggered", detail.notificationTriggered)
                    put("requestUrl", detail.requestUrl)
                    put("finalUrl", detail.finalUrl)
                    detail.responseCode?.let { put("responseCode", it) }
                    put("technicalDetails", detail.technicalDetails)
                    put("previousContent", detail.previousContent)
                    put("currentContent", detail.currentContent)
                    put("difference", detail.difference)
                })
            }
        })
    }

    private fun JSONObject.toEntry(): PortalPollHistoryEntry {
        val detailArray = optJSONArray("details") ?: JSONArray()
        return PortalPollHistoryEntry(
            timestamp = optLong("timestamp"),
            status = optString("status"),
            notificationTriggered = optBoolean("notificationTriggered"),
            details = (0 until detailArray.length()).map { index ->
                detailArray.getJSONObject(index).let { detail ->
                    PortalPollHistoryDetail(
                        category = detail.optString("category"),
                        summary = detail.optString("summary"),
                        changed = detail.optBoolean("changed"),
                        notificationEnabled = detail.optBooleanOrNull("notificationEnabled"),
                        notificationTriggered = detail.optBoolean("notificationTriggered"),
                        requestUrl = detail.optString("requestUrl"),
                        finalUrl = detail.optString("finalUrl"),
                        responseCode = detail.optIntOrNull("responseCode"),
                        technicalDetails = detail.optString("technicalDetails"),
                        previousContent = detail.optString("previousContent"),
                        currentContent = detail.optString("currentContent"),
                        difference = detail.optString("difference")
                    )
                }
            }
        )
    }

    private fun JSONObject.optBooleanOrNull(key: String): Boolean? =
        if (has(key) && !isNull(key)) getBoolean(key) else null

    private fun JSONObject.optIntOrNull(key: String): Int? =
        if (has(key) && !isNull(key)) getInt(key) else null
}

internal fun latestUnreadPortalChange(
    entries: List<PortalPollHistoryEntry>,
    acknowledgedAt: (nativeType: String) -> Long
): PortalHomeChangeNotice? = entries.firstNotNullOfOrNull { entry ->
    entry.details.firstNotNullOfOrNull detail@{ detail ->
        if (!detail.changed) return@detail null
        val nativeType = detail.category.homeNoticeNativeType() ?: return@detail null
        if (entry.timestamp <= acknowledgedAt(nativeType)) return@detail null
        PortalHomeChangeNotice(
            timestamp = entry.timestamp,
            category = detail.category,
            nativeType = nativeType
        )
    }
}

private fun String.homeNoticeNativeType(): String? = when (this) {
    "课表" -> "schedule"
    "成绩" -> "grade"
    "考试" -> "exam"
    else -> null
}
