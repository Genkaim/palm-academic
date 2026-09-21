package cn.edu.cupk.portalreader

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
        return normalized.contains("courseName", ignoreCase = true) ||
            normalized.contains("lessonName", ignoreCase = true) ||
            normalized.contains("courseId", ignoreCase = true) ||
            parseTables(value).any { it.rows.isNotEmpty() }
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
            val firstIsHeader = parsedRows.first().second
            ParsedTable(
                headers = if (firstIsHeader) parsedRows.first().first else emptyList(),
                rows = parsedRows.drop(if (firstIsHeader) 1 else 0).map { it.first }
            )
        }
    }.toList()

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
