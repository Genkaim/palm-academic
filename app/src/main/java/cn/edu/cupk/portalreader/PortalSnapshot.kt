package cn.edu.cupk.portalreader

import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

object PortalSnapshot {
    data class ParsedTable(
        val headers: List<String>,
        val rows: List<List<String>>
    )

    fun stableHash(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.replace(Regex("\\s+"), " ").trim().toByteArray())
        .joinToString("") { "%02x".format(it) }

    fun visibleDocument(html: String): String = html
        .replace(Regex("<script[\\s\\S]*?</script>", RegexOption.IGNORE_CASE), " ")
        .replace(Regex("<style[\\s\\S]*?</style>", RegexOption.IGNORE_CASE), " ")
        .replace(Regex("<[^>]+>"), " ")
        .replace("&nbsp;", " ")
        .replace(Regex("\\s+"), " ")
        .trim()

    fun hasCourseEntries(value: String): Boolean {
        val normalized = value.trim()
        if (normalized.isBlank() || normalized in setOf("[]", "{}", "null")) return false
        if (normalized.contains("courseName", ignoreCase = true) ||
            normalized.contains("lessonName", ignoreCase = true) ||
            normalized.contains("courseId", ignoreCase = true) ||
            Regex("\"lessonIds\"\\s*:\\s*\\[\\s*\\d", RegexOption.IGNORE_CASE)
                .containsMatchIn(normalized) ||
            Regex("\"lessons\"\\s*:\\s*\\[\\s*\\{", RegexOption.IGNORE_CASE)
                .containsMatchIn(normalized) ||
            parseTables(value).any { it.rows.isNotEmpty() }
        ) return true

        // Different EAMS deployments wrap the same schedule in keys such as data,
        // records, result or list. Treat a non-empty array of objects under these
        // conventional payload keys as course data instead of reporting a false
        // "未识别到课程数据" result.
        return Regex(
            "\\\"(?:data|records|rows|list|items|result|content)\\\"\\s*:\\s*\\[\\s*\\{",
            RegexOption.IGNORE_CASE
        ).containsMatchIn(normalized)
    }

    fun tableRows(html: String, className: String? = null): Set<String> {
        return parseTables(html, className)
            .flatMap { it.rows }
            .map { cells -> cells.joinToString(" | ") }
            .filter { row ->
                row.isNotBlank() &&
                    !row.contains("课程名称") &&
                    !row.contains("暂无") &&
                    !row.contains("没有")
            }
            .toSet()
    }

    fun parseTables(html: String, className: String? = null): List<ParsedTable> = Regex(
        """<table\b([^>]*)>([\s\S]*?)</table>""",
        RegexOption.IGNORE_CASE
    ).findAll(html).filter { tableMatch ->
        className == null || Regex(
            """class\s*=\s*[\"'][^\"']*\b${Regex.escape(className)}\b[^\"']*[\"']""",
            RegexOption.IGNORE_CASE
        ).containsMatchIn(tableMatch.groupValues[1])
    }.mapNotNull { tableMatch ->
        val parsedRows = Regex("""<tr\b[^>]*>([\s\S]*?)</tr>""", RegexOption.IGNORE_CASE)
            .findAll(tableMatch.groupValues[2])
            .mapNotNull { row ->
                val rowHtml = row.groupValues[1]
                val cells = Regex("""<t[dh]\b[^>]*>([\s\S]*?)</t[dh]>""", RegexOption.IGNORE_CASE)
                    .findAll(rowHtml)
                    .map { visibleDocument(it.groupValues[1]) }
                    .toList()
                cells.takeIf { it.any(String::isNotBlank) }?.let {
                    it to Regex("""<th\b""", RegexOption.IGNORE_CASE).containsMatchIn(rowHtml)
                }
            }
            .toList()
        if (parsedRows.isEmpty()) null else {
            val firstIsHeader = parsedRows.first().second || looksLikeHeaderRow(parsedRows.first().first)
            ParsedTable(
                headers = if (firstIsHeader) parsedRows.first().first else emptyList(),
                rows = parsedRows.drop(if (firstIsHeader) 1 else 0).map { it.first }
            )
        }
    }.toList()

    private fun looksLikeHeaderRow(cells: List<String>): Boolean {
        if (cells.isEmpty()) return false
        val headerTerms = setOf(
            "课程", "课程名称", "课程代码", "学期", "学分", "绩点", "成绩", "成绩明细",
            "分项成绩明细", "总成绩明细", "考试时间", "考试地点", "地点", "座位号",
            "教师", "老师", "课程性质", "课程类别"
        )
        val matches = cells.count { cell ->
            val normalized = cell.replace(Regex("[：:\\s]+"), "").trim()
            normalized in headerTerms || headerTerms.any { normalized == it }
        }
        return matches >= minOf(2, cells.size)
    }

    /**
     * Produces a compact, human-comparable course snapshot. School-specific endpoints remain in
     * the definition file; this generic filter keeps every non-empty course/lesson/schedule field.
     */
    fun courseDataJson(payload: String, semesterId: String): String {
        val normalized = payload.trim()
        val root = runCatching { JSONObject(normalized) }.getOrNull()
        if (root !is JSONObject) return parsedDataJson(payload, "course")

        val result = JSONObject()
            .put("type", "course")
            .put("semesterId", semesterId)
        root.keys().asSequence().toList().sorted().forEach { key ->
            val lower = key.lowercase()
            val value = root.opt(key)
            if (
                ("course" in lower || "lesson" in lower || "schedule" in lower) &&
                hasMeaningfulJsonValue(value)
            ) {
                result.put(key, value)
            }
        }
        if (result.length() == 2) {
            // Keep the complete response when a school uses different field names.
            // Dropping it here made a valid logged-in response look empty in the
            // background change log even though the WebView rendered it correctly.
            result.put("payload", root)
        }
        return result.toString(2)
    }

    private fun hasMeaningfulJsonValue(value: Any?): Boolean = when (value) {
        null, JSONObject.NULL -> false
        is String -> value.isNotBlank()
        is JSONArray -> value.length() > 0
        is JSONObject -> value.length() > 0
        else -> true
    }

    fun parsedDataJson(html: String, type: String, tableClass: String? = null): String {
        val normalized = html.trim()
        if (normalized.startsWith('{') || normalized.startsWith('[')) return prettyJson(normalized)
        val requestedTables = tableClass?.let { parseTables(html, it) }.orEmpty()
        val tables = requestedTables.ifEmpty { parseTables(html) }
        val visibleText = visibleDocument(html)
        return buildString {
            appendLine("{")
            appendLine("  \"type\": ${jsonString(type)},")
            appendLine("  \"tables\": [")
            tables.forEachIndexed { tableIndex, table ->
                appendLine("    {")
                appendLine("      \"headers\": ${jsonArray(table.headers)},")
                appendLine("      \"rows\": [")
                table.rows.forEachIndexed { rowIndex, row ->
                    append("        ${jsonArray(row)}")
                    if (rowIndex != table.rows.lastIndex) append(',')
                    appendLine()
                }
                appendLine("      ]")
                append("    }")
                if (tableIndex != tables.lastIndex) append(',')
                appendLine()
            }
            appendLine("  ],")
            appendLine("  \"text\": ${jsonString(visibleText)}")
            append('}')
        }
    }

    fun diagnosticJson(type: String, status: String): String = buildString {
        appendLine("{")
        appendLine("  \"type\": ${jsonString(type)},")
        appendLine("  \"dataStatus\": ${jsonString(status)}")
        append('}')
    }

    fun historyDisplayContent(value: String): String {
        val trimmed = value.trim()
        return if (trimmed.startsWith('<') || trimmed.contains("<html", ignoreCase = true)) {
            parsedDataJson(value, "legacy-html")
        } else if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
            prettyJson(trimmed)
        } else {
            value
        }
    }

    private fun prettyJson(value: String): String = buildString {
        var indent = 0
        var inString = false
        var escaped = false
        var pendingSpace = false
        fun newline() {
            append('\n')
            repeat(indent * 2) { append(' ') }
        }
        value.forEach { character ->
            if (inString) {
                append(character)
                if (escaped) escaped = false
                else if (character == '\\') escaped = true
                else if (character == '"') inString = false
                return@forEach
            }
            when (character) {
                '"' -> {
                    if (pendingSpace) {
                        append(' ')
                        pendingSpace = false
                    }
                    append(character)
                    inString = true
                }
                '{', '[' -> {
                    append(character)
                    indent++
                    newline()
                }
                '}', ']' -> {
                    indent = (indent - 1).coerceAtLeast(0)
                    newline()
                    append(character)
                }
                ',' -> {
                    append(character)
                    newline()
                }
                ':' -> {
                    append(": ")
                    pendingSpace = false
                }
                '\n', '\r', '\t', ' ' -> pendingSpace = true
                else -> {
                    if (pendingSpace) {
                        append(' ')
                        pendingSpace = false
                    }
                    append(character)
                }
            }
        }
    }.trim()

    private fun jsonArray(values: List<String>): String =
        values.joinToString(prefix = "[", postfix = "]") { jsonString(it) }

    private fun jsonString(value: String): String = buildString {
        append('"')
        value.forEach { character ->
            when (character) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '\b' -> append("\\b")
                '\u000C' -> append("\\f")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> if (character.code < 0x20) {
                    append("\\u%04x".format(character.code))
                } else {
                    append(character)
                }
            }
        }
        append('"')
    }

    fun hasTable(html: String, className: String): Boolean = Regex(
        """<table\b[^>]*class\s*=\s*[\"'][^\"']*\b${Regex.escape(className)}\b[^\"']*[\"'][^>]*>""",
        RegexOption.IGNORE_CASE
    ).containsMatchIn(html)
}
