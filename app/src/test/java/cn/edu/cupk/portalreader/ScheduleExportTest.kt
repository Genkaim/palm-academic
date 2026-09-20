package cn.edu.cupk.portalreader

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ScheduleExportTest {
    private fun schedule(weeks: String = "1-2") = MaterialSection.Schedule(
        title = "2026-2027学年秋季学期",
        semesterStartDate = "2026-08-31",
        days = listOf(
            ScheduleDay(
                name = "星期一",
                lessons = listOf(
                    MaterialCardItem(
                        title = "工程制图",
                        subtitle = "160408T027.17",
                        accent = "",
                        fields = listOf("教学班" to "自动化25-[3-4]班"),
                        schedule = MaterialCourseSchedule(
                            weeks = weeks,
                            startSection = "1",
                            endSection = "2",
                            teacher = "刘申",
                            location = "C9楼I区402",
                            startTime = "09:30",
                            endTime = "11:05"
                        )
                    )
                )
            )
        )
    )

    @Test
    fun wakeUpCsv_keepsTeacherAndLocationInSeparateColumns() {
        val csv = scheduleToCsv(schedule())

        assertTrue(csv.startsWith("课程名称,星期,开始节数,结束节数,老师,地点,周数"))
        assertTrue(csv.contains("\"刘申\",\"C9楼I区402\",\"1-2\""))
    }

    @Test
    fun ics_usesTimedEventsInsteadOfAllDayDates() {
        val ics = scheduleToIcs(schedule())

        assertFalse(ics.contains("VALUE=DATE"))
        assertTrue(ics.contains("DTSTART;TZID=Asia/Shanghai:20260831T093000"))
        assertTrue(ics.contains("DTEND;TZID=Asia/Shanghai:20260831T110500"))
        assertTrue(ics.contains("DTSTART;TZID=Asia/Shanghai:20260907T093000"))
        assertTrue(ics.contains("LOCATION:C9楼I区402"))
    }

    @Test
    fun ics_expandsOddEvenWeekRulesPrecisely() {
        val ics = scheduleToIcs(schedule("1-4双"))

        assertFalse(ics.contains("20260831T093000"))
        assertTrue(ics.contains("20260907T093000"))
        assertFalse(ics.contains("20260914T093000"))
        assertTrue(ics.contains("20260921T093000"))
    }
}
