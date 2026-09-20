package cn.edu.cupk.portalreader

import java.security.MessageDigest

object PortalSnapshot {
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
            normalized.contains("courseId", ignoreCase = true)
    }

    fun tableRows(html: String, className: String): Set<String> {
        val table = Regex(
            """<table\b[^>]*class\s*=\s*[\"'][^\"']*\b${Regex.escape(className)}\b[^\"']*[\"'][^>]*>([\s\S]*?)</table>""",
            RegexOption.IGNORE_CASE
        ).find(html)?.groupValues?.getOrNull(1) ?: return emptySet()
        return Regex("""<tr\b[^>]*>([\s\S]*?)</tr>""", RegexOption.IGNORE_CASE)
            .findAll(table)
            .map { row ->
                val cells = Regex("""<t[dh]\b[^>]*>([\s\S]*?)</t[dh]>""", RegexOption.IGNORE_CASE)
                    .findAll(row.groupValues[1])
                    .map { visibleDocument(it.groupValues[1]) }
                    .filter(String::isNotBlank)
                    .toList()
                if (cells.isNotEmpty()) cells.joinToString(" | ")
                else visibleDocument(row.groupValues[1])
            }
            .filter { row ->
                row.isNotBlank() &&
                    !row.contains("课程名称") &&
                    !row.contains("暂无") &&
                    !row.contains("没有")
            }
            .toSet()
    }

    fun hasTable(html: String, className: String): Boolean = Regex(
        """<table\b[^>]*class\s*=\s*[\"'][^\"']*\b${Regex.escape(className)}\b[^\"']*[\"'][^>]*>""",
        RegexOption.IGNORE_CASE
    ).containsMatchIn(html)
}
