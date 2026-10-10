package cn.edu.cupk.portalreader

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CourseRowsEamsTest {

    private val payload = """
    {
      "lessonIds": [319438, 321124],
      "lessons": [
        {
          "id": 319438,
          "code": "160512C012.01",
          "nameZh": "自动化25-1班",
          "course": {"id": 900, "nameZh": "Python程序设计", "nameEn": "Python Programming"},
          "scheduleText": {
            "dateTimePlacePersonText": {
              "text": "4~12周 星期三 6~7节 克拉玛依校区 C5楼II区313机房 杨鹏;\n4~12周 星期五 8~9节 克拉玛依校区 C5楼II区313机房 杨鹏"
            }
          }
        },
        {
          "id": 321124,
          "code": "101099M003.70",
          "nameZh": "大学体育III教学班",
          "course": {"id": 901, "nameZh": "大学体育III"},
          "scheduleText": {
            "dateTimePlacePersonText": {"text": "1~16周 星期一 3~4节 克拉玛依校区 田径场 张安君"}
          }
        }
      ]
    }
    """.trimIndent()

    @Test
    fun eams_get_data_yields_semantic_rows_not_bare_ids() {
        val rows = PortalLogDetails.courseRows(payload)
        // 3 schedule segments across 2 lessons.
        assertTrue("expected 3 rows, got $rows", rows.size == 3)
        val joined = rows.joinToString("\n")
        // Real course name, not the teaching-class name, and no ID-only fallback.
        assertTrue(joined.contains("Python程序设计"))
        assertTrue(joined.contains("大学体育III"))
        assertFalse(rows.any { it.startsWith("课程 ID") })
        // Weekday / section / room / teacher carried through, tildes normalised to hyphens.
        assertTrue(joined.contains("星期三"))
        assertTrue(joined.contains("6-7节"))
        assertTrue(joined.contains("C5楼II区313机房"))
        assertTrue(joined.contains("杨鹏"))
        // Stable across repeated parses (comparison must not flap).
        assertTrue(rows == PortalLogDetails.courseRows(payload))
    }
}
