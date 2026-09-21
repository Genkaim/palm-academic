package cn.edu.cupk.portalreader

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

data class PortalPollHistoryDetail(
    val category: String,
    val summary: String,
    val changed: Boolean = false,
    val notificationTriggered: Boolean = false,
    val difference: String = ""
)

data class PortalPollHistoryEntry(
    val timestamp: Long,
    val status: String,
    val notificationTriggered: Boolean,
    val details: List<PortalPollHistoryDetail>
)

object PortalPollHistory {
    private const val FILE_NAME = "portal_poll_history.json"
    private const val MAX_ENTRIES = 200
    private const val MAX_PREVIEW_LENGTH = 1200
    private val lock = Any()

    fun read(context: Context): List<PortalPollHistoryEntry> = synchronized(lock) {
        readUnlocked(context)
    }

    fun append(context: Context, entry: PortalPollHistoryEntry) = synchronized(lock) {
        val entries = (listOf(entry) + readUnlocked(context)).take(MAX_ENTRIES)
        writeUnlocked(context, entries)
    }

    fun clear(context: Context) = synchronized(lock) {
        historyFile(context).delete()
    }

    fun preview(value: String): String = value
        .replace("\u001E", "\n")
        .replace(Regex("[\\t\\r ]+"), " ")
        .replace(Regex("\\n+"), "\n")
        .trim()
        .let { if (it.length <= MAX_PREVIEW_LENGTH) it else it.take(MAX_PREVIEW_LENGTH) + "…" }

    fun difference(previous: String?, current: String): String {
        if (previous == null) return "更新后：${current.ifBlank { "（空）" }}"
        val before = previous.ifBlank { "（空）" }
        val after = current.ifBlank { "（空）" }
        return "更新前：$before\n更新后：$after"
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
                    put("notificationTriggered", detail.notificationTriggered)
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
                        notificationTriggered = detail.optBoolean("notificationTriggered"),
                        difference = detail.optString("difference")
                    )
                }
            }
        )
    }
}
