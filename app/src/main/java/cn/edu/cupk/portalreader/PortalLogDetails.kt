package cn.edu.cupk.portalreader

import org.json.JSONArray
import org.json.JSONObject

/** Builds the compact, human-readable business data used by polling and its history log. */
internal object PortalLogDetails {
    private val courseTitleKeys = setOf(
        "coursename", "lessonname", "coursefullname", "lessonfullname"
    )
    private val courseCodeKeys = setOf("coursecode", "lessoncode", "code")
    private val courseIdKeys = setOf("lessonid", "courseid", "id")
    private val weekdayKeys = setOf("weekday", "dayofweek", "weekdays", "day")
    private val startSectionKeys = setOf(
        "startunit", "startsection", "startperiod", "beginunit", "beginsection"
    )
    private val endSectionKeys = setOf(
        "endunit", "endsection", "endperiod", "finishunit", "finishsection"
    )
    private val weekKeys = setOf("weeks", "weekindices", "weekindexes", "weeklist")
    private val roomKeys = setOf(
        "room", "roomname", "classroom", "classroomname", "location", "place"
    )
    private val teacherKeys = setOf(
        "teacher", "teachers", "teachername", "teachernames", "instructor", "instructors"
    )
    private val timeKeys = setOf("time", "coursetime", "scheduletime", "timeperiod")

    fun rowsFor(nativeType: String?, content: String): List<String> = when (nativeType) {
        "schedule" -> materialRows(content, nativeType).ifEmpty { courseRows(content) }
        "grade", "exam", "program" -> materialRows(content, nativeType)
        else -> materialRows(content, nativeType)
    }

    fun courseRows(payload: String): List<String> {
        val root = parseJson(payload) ?: return emptyList()
        val lessons = mutableListOf<JSONObject>()
        collectLessonObjects(root, parentKey = "", destination = lessons)
        val rows = lessons.flatMap(::formatLesson).normalizeRows()
        if (rows.isNotEmpty()) return rows

        val lessonIds = mutableListOf<String>()
        collectValuesForKey(root, "lessonids", lessonIds)
        return lessonIds.distinct().sorted().map { "课程 ID：$it" }
    }

    fun materialRows(content: String, nativeType: String?): List<String> {
        val pageRows = runCatching { parseMaterialPage(content) }.getOrNull()
            ?.takeIf { it.sections.isNotEmpty() }
            ?.let { page ->
                buildList {
                    page.sections.forEach { section ->
                        when (section) {
                            is MaterialSection.Schedule -> section.days.forEach { day ->
                                day.lessons.forEach { lesson ->
                                    add(formatScheduleCard(day.name, lesson))
                                }
                            }
                            is MaterialSection.Cards -> section.cards.forEach { card ->
                                add(formatCard(section.title, card, nativeType))
                            }
                            is MaterialSection.Table -> section.rows.forEach { row ->
                                add(formatTableRow(section.title, section.headers, row))
                            }
                            is MaterialSection.Stats -> section.items.forEach { item ->
                                if (item.label.isNotBlank() || item.value.isNotBlank()) {
                                    add("${section.title}｜${item.label}：${item.value}".trimSeparators())
                                }
                            }
                            is MaterialSection.Fields -> if (section.fields.isNotEmpty()) {
                                add(
                                    (listOf(section.title) + section.fields.map { (label, value) ->
                                        "$label：$value"
                                    })
                                        .map(String::trim)
                                        .filter(String::isNotBlank)
                                        .joinToString("｜")
                                        .trimSeparators()
                                )
                            }
                            is MaterialSection.Text -> section.paragraphs.forEach { paragraph ->
                                if (paragraph.isNotBlank()) add("${section.title}｜$paragraph".trimSeparators())
                            }
                            is MaterialSection.Links -> Unit
                            is MaterialSection.Program -> {
                                val summary = listOfNotNull(
                                    section.completedCredits.takeIf(String::isNotBlank)?.let { "已修学分：$it" },
                                    section.requiredCredits.takeIf(String::isNotBlank)?.let { "要求学分：$it" }
                                )
                                if (summary.isNotEmpty()) {
                                    add((listOf(section.title) + summary).joinToString("｜").trimSeparators())
                                }
                            }
                        }
                    }
                }
            }
            .orEmpty()
            .normalizeRows()
        if (pageRows.isNotEmpty()) return pageRows

        val root = parseJson(content) as? JSONObject ?: return emptyList()
        val tables = root.optJSONArray("tables") ?: return emptyList()
        return buildList {
            for (tableIndex in 0 until tables.length()) {
                val table = tables.optJSONObject(tableIndex) ?: continue
                val headers = table.optJSONArray("headers").toStringList()
                val rows = table.optJSONArray("rows") ?: continue
                for (rowIndex in 0 until rows.length()) {
                    add(formatTableRow("", headers, rows.optJSONArray(rowIndex).toStringList()))
                }
            }
        }.normalizeRows()
    }

    fun encode(rows: List<String>): String = JSONArray(rows.normalizeRows()).toString()

    fun describe(previousSnapshot: String?, currentRows: List<String>, changed: Boolean): String {
        val current = currentRows.normalizeRows()
        if (previousSnapshot == null) return currentData(current)

        val previous = decode(previousSnapshot)
        if (!changed) return currentData(current)

        val previousSet = previous.toSet()
        val currentSet = current.toSet()
        val added = current.filterNot(previousSet::contains)
        val removed = previous.filterNot(currentSet::contains)
        return buildString {
            if (added.isNotEmpty()) {
                appendLine("新增或变更后（${added.size} 项）：")
                appendRows(added)
            }
            if (removed.isNotEmpty()) {
                if (isNotEmpty()) appendLine()
                appendLine("移除或变更前（${removed.size} 项）：")
                appendRows(removed)
            }
            if (added.isEmpty() && removed.isEmpty()) {
                appendLine("业务快照发生变化，但已识别的展示字段一致。")
                append(currentData(current))
            }
        }.trimEnd()
    }

    private fun currentData(rows: List<String>): String = buildString {
        appendLine("当前数据（${rows.size} 项）：")
        if (rows.isEmpty()) append("• 暂无可展示的具体条目") else appendRows(rows)
    }.trimEnd()

    private fun StringBuilder.appendRows(rows: List<String>) {
        rows.forEachIndexed { index, row ->
            append("• ").append(row)
            if (index != rows.lastIndex) appendLine()
        }
    }

    private fun decode(value: String): List<String> = runCatching {
        val array = JSONArray(value)
        (0 until array.length()).mapNotNull { index ->
            array.optString(index).trim().takeIf(String::isNotBlank)
        }.normalizeRows()
    }.getOrDefault(emptyList())

    private fun formatScheduleCard(day: String, card: MaterialCardItem): String {
        val schedule = card.schedule
        val details = if (schedule == null) {
            card.fields.mapNotNull { (label, value) ->
                value.takeIf(String::isNotBlank)?.let { "$label：$it" }
            }
        } else {
            listOfNotNull(
                day.takeIf(String::isNotBlank),
                sectionText(schedule.startSection, schedule.endSection),
                schedule.weeks.takeIf(String::isNotBlank)?.let { "第${it}周" },
                schedule.startTime.takeIf(String::isNotBlank)?.let { start ->
                    schedule.endTime.takeIf(String::isNotBlank)?.let { "$start-$it" } ?: start
                },
                schedule.location.takeIf(String::isNotBlank)?.let { "地点：$it" },
                schedule.teacher.takeIf(String::isNotBlank)?.let { "教师：$it" }
            )
        }
        return (listOf(courseName(card.title, card.subtitle)) + details)
            .joinToString("｜")
            .trimSeparators()
    }

    private fun formatCard(sectionTitle: String, card: MaterialCardItem, nativeType: String?): String {
        val accentLabel = when (nativeType) {
            "grade" -> "成绩"
            "exam" -> "状态"
            else -> "结果"
        }
        val details = buildList {
            sectionTitle.takeIf(String::isNotBlank)?.let(::add)
            add(courseName(card.title, card.subtitle))
            card.accent.takeIf(String::isNotBlank)?.let { add("$accentLabel：$it") }
            card.fields.forEach { (label, value) ->
                if (value.isNotBlank()) add("$label：$value")
            }
        }
        return details.joinToString("｜").trimSeparators()
    }

    private fun formatTableRow(title: String, headers: List<String>, row: List<String>): String {
        val values = row.mapIndexedNotNull { index, value ->
            value.takeIf(String::isNotBlank)?.let {
                headers.getOrNull(index)?.takeIf(String::isNotBlank)?.let { header -> "$header：$it" }
                    ?: it
            }
        }
        return (listOf(title) + values).joinToString("｜").trimSeparators()
    }

    private fun formatLesson(lesson: JSONObject): List<String> {
        val title = lesson.directText(courseTitleKeys).ifBlank { return emptyList() }
        val code = lesson.directText(courseCodeKeys)
        val id = lesson.directText(courseIdKeys)
        val base = courseName(title, code.ifBlank { id })
        val schedules = mutableListOf<JSONObject>()
        lesson.keys().asSequence().forEach { key ->
            val normalized = normalizeKey(key)
            if (("schedule" in normalized || "arrange" in normalized) &&
                "department" !in normalized
            ) {
                collectScheduleObjects(lesson.opt(key), schedules)
            }
        }
        if (schedules.isEmpty() && lesson.hasScheduleFields()) schedules += lesson
        if (schedules.isEmpty()) return listOf(base)
        return schedules.distinctBy(JSONObject::toString).map { schedule ->
            val details = listOfNotNull(
                formatWeekday(schedule.findValue(weekdayKeys)),
                sectionText(
                    schedule.findText(startSectionKeys),
                    schedule.findText(endSectionKeys)
                ),
                formatWeeks(schedule.findValue(weekKeys)),
                schedule.findText(timeKeys).takeIf(String::isNotBlank),
                schedule.findText(roomKeys).takeIf(String::isNotBlank)?.let { "地点：$it" },
                schedule.findNames(teacherKeys).takeIf(String::isNotBlank)?.let { "教师：$it" }
            )
            (listOf(base) + details).joinToString("｜").trimSeparators()
        }
    }

    private fun collectLessonObjects(value: Any?, parentKey: String, destination: MutableList<JSONObject>) {
        when (value) {
            is JSONObject -> {
                val explicitTitle = value.directText(courseTitleKeys)
                if (explicitTitle.isNotBlank()) destination += value
                value.keys().asSequence().forEach { key ->
                    collectLessonObjects(value.opt(key), normalizeKey(key), destination)
                }
            }
            is JSONArray -> for (index in 0 until value.length()) {
                val item = value.opt(index)
                if (item is JSONObject &&
                    ("lesson" in parentKey || "course" in parentKey) &&
                    item.directText(courseTitleKeys).isNotBlank()
                ) {
                    destination += item
                }
                collectLessonObjects(item, parentKey, destination)
            }
        }
    }

    private fun collectScheduleObjects(value: Any?, destination: MutableList<JSONObject>) {
        when (value) {
            is JSONObject -> {
                if (value.hasScheduleFields()) destination += value
                else value.keys().asSequence().forEach { collectScheduleObjects(value.opt(it), destination) }
            }
            is JSONArray -> for (index in 0 until value.length()) {
                collectScheduleObjects(value.opt(index), destination)
            }
        }
    }

    private fun JSONObject.hasScheduleFields(): Boolean {
        val keys = keys().asSequence().map(::normalizeKey).toSet()
        return keys.any { it in weekdayKeys || it in startSectionKeys || it in weekKeys || it in roomKeys }
    }

    private fun JSONObject.directText(keys: Set<String>): String {
        this.keys().asSequence().forEach { key ->
            if (normalizeKey(key) in keys) return scalarText(opt(key))
        }
        return ""
    }

    private fun JSONObject.findValue(keys: Set<String>): Any? {
        this.keys().asSequence().forEach { key ->
            if (normalizeKey(key) in keys) return opt(key)
        }
        return null
    }

    private fun JSONObject.findText(keys: Set<String>): String = scalarText(findValue(keys))

    private fun JSONObject.findNames(keys: Set<String>): String {
        val value = findValue(keys) ?: return ""
        return extractNames(value).distinct().joinToString("/")
    }

    private fun extractNames(value: Any?): List<String> = when (value) {
        is String -> listOf(value.trim()).filter(String::isNotBlank)
        is Number -> listOf(value.toString())
        is JSONObject -> {
            val direct = value.directText(setOf("name", "teachername", "fullname"))
            if (direct.isNotBlank()) listOf(direct) else value.keys().asSequence()
                .flatMap { extractNames(value.opt(it)).asSequence() }
                .toList()
        }
        is JSONArray -> (0 until value.length()).flatMap { extractNames(value.opt(it)) }
        else -> emptyList()
    }

    private fun collectValuesForKey(value: Any?, targetKey: String, destination: MutableList<String>) {
        when (value) {
            is JSONObject -> value.keys().asSequence().forEach { key ->
                val child = value.opt(key)
                if (normalizeKey(key) == targetKey) {
                    when (child) {
                        is JSONArray -> for (index in 0 until child.length()) {
                            scalarText(child.opt(index)).takeIf(String::isNotBlank)?.let(destination::add)
                        }
                        else -> scalarText(child).takeIf(String::isNotBlank)?.let(destination::add)
                    }
                } else collectValuesForKey(child, targetKey, destination)
            }
            is JSONArray -> for (index in 0 until value.length()) {
                collectValuesForKey(value.opt(index), targetKey, destination)
            }
        }
    }

    private fun formatWeekday(value: Any?): String? {
        val text = scalarText(value)
        if (text.isBlank()) return null
        val number = text.toIntOrNull()
        return if (number in 1..7) {
            listOf("星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日")[number!! - 1]
        } else text
    }

    private fun sectionText(start: String, end: String): String? {
        if (start.isBlank() && end.isBlank()) return null
        val range = when {
            start.isBlank() -> end
            end.isBlank() || start == end -> start
            else -> "$start-$end"
        }
        return "第${range}节"
    }

    private fun formatWeeks(value: Any?): String? {
        if (value == null || value == JSONObject.NULL) return null
        val numbers = when (value) {
            is JSONArray -> (0 until value.length()).mapNotNull { value.optString(it).toIntOrNull() }
            else -> emptyList()
        }.distinct().sorted()
        if (numbers.isEmpty()) {
            val text = scalarText(value)
            return text.takeIf(String::isNotBlank)?.let { "第${it}周" }
        }
        val ranges = mutableListOf<String>()
        var start = numbers.first()
        var end = start
        numbers.drop(1).forEach { week ->
            if (week == end + 1) end = week else {
                ranges += if (start == end) "$start" else "$start-$end"
                start = week
                end = week
            }
        }
        ranges += if (start == end) "$start" else "$start-$end"
        return "第${ranges.joinToString("、")}周"
    }

    private fun courseName(title: String, code: String): String =
        if (code.isBlank() || code == title) title else "$title（$code）"

    private fun scalarText(value: Any?): String = when (value) {
        null, JSONObject.NULL -> ""
        is String -> value.trim()
        is Number, is Boolean -> value.toString()
        else -> ""
    }

    private fun parseJson(value: String): Any? = runCatching {
        val trimmed = value.trim()
        when {
            trimmed.startsWith("{") -> JSONObject(trimmed)
            trimmed.startsWith("[") -> JSONArray(trimmed)
            else -> null
        }
    }.getOrNull()

    private fun JSONArray?.toStringList(): List<String> = if (this == null) emptyList() else
        (0 until length()).map { optString(it) }

    private fun List<String>.normalizeRows(): List<String> = asSequence()
        .map { it.replace(Regex("\\s+"), " ").trim().trimSeparators() }
        .filter(String::isNotBlank)
        .distinct()
        .sorted()
        .toList()

    private fun String.trimSeparators(): String = trim().trim('｜', '·', ' ', '：')

    private fun normalizeKey(value: String): String = value.filter(Char::isLetterOrDigit).lowercase()
}
