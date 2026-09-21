package cn.edu.cupk.portalreader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PortalPollWorkerTest {
    @Test
    fun visibleDocument_ignoresScriptsAndStyles() {
        val html = "<html><style>.x{color:red}</style><body><h1>考试信息</h1><script>token=123</script><p>暂无安排</p></body></html>"
        assertEquals("考试信息 暂无安排", PortalSnapshot.visibleDocument(html))
    }

    @Test
    fun stableHash_changesWithMeaningfulContent() {
        val first = PortalSnapshot.stableHash("课程 A")
        val second = PortalSnapshot.stableHash("课程 B")
        assertFalse(first == second)
    }

    @Test
    fun courseNotification_detectsPublishAndLaterChange() {
        val emptyHash = PortalSnapshot.stableHash("[]")
        val publishedHash = PortalSnapshot.stableHash("[{courseName:'高等数学'}]")
        assertTrue(PortalPollLogic.courseChanged(emptyHash, "20251", publishedHash, "20251", true))
        assertTrue(PortalPollLogic.courseChanged(publishedHash, "20251", "changed", "20251", true))
        assertFalse(PortalPollLogic.courseChanged(null, null, publishedHash, "20251", true))
    }

    @Test
    fun gradeNotification_requiresBaselineAndChange() {
        assertFalse(PortalPollLogic.contentChanged(null, "first"))
        assertFalse(PortalPollLogic.contentChanged("same", "same"))
        assertTrue(PortalPollLogic.contentChanged("old", "new"))
    }

    @Test
    fun examNotification_detectsAdditionsAndFieldChanges() {
        assertTrue(PortalPollLogic.contentChanged("考试 A", "考试 A\u001E考试 B"))
        assertTrue(
            PortalPollLogic.contentChanged(
                "高等数学 | 10:00 | A101",
                "高等数学 | 14:00 | B305"
            )
        )
    }

    @Test
    fun loginRedirectWithQuery_isAuthenticationFailure() {
        assertTrue(AuthRepository.isLoginPage("", "https://example.test/student/login?expired=1"))
    }

    @Test
    fun monitorDefinition_resolvesConfiguredStudentAndSemesterPlaceholders() {
        val monitor = PortalMonitorDefinition(
            coursePagePath = "/course-table",
            courseDataPathTemplate = "/course-data?semester={semesterId}&student={studentId}",
            gradeDataPathTemplate = "/grade/{studentId}?semester={semesterId}",
            examDataPathTemplate = "/exam/{studentId}",
            semesterIdPatterns = listOf("semesterId=(\\d+)"),
            studentIdPatterns = listOf("/course-table/info/(\\d+)")
        )

        assertEquals("483", monitor.extractSemesterId("semesterId=483"))
        assertEquals("102030", monitor.extractStudentId("https://example.test/course-table/info/102030"))
        assertEquals(
            "https://example.test/student/course-data?semester=483&student=102030",
            monitor.courseDataUrl("https://example.test/student", "483", "102030")
        )
        assertTrue(monitor.requiresSemesterId(schedule = true, grade = false, exam = false))
        assertFalse(monitor.requiresSemesterId(schedule = false, grade = false, exam = true))
        assertTrue(monitor.requiresStudentId(schedule = false, grade = true, exam = false))
    }

    @Test
    fun monitorDefinition_extractsStudentIdFromGenericSignedInAccountLabel() {
        val monitor = PortalMonitorDefinition(
            coursePagePath = "/course-table",
            courseDataPathTemplate = "/course-data?student={studentId}",
            gradeDataPathTemplate = "/grade/{studentId}",
            examDataPathTemplate = "/exam/{studentId}",
            semesterIdPatterns = emptyList(),
            studentIdPatterns = listOf("/course-table/info/(\\d+)")
        )

        assertEquals(
            "2025016766",
            monitor.extractStudentId("课表 教务系统 --> 曹玄恒(2025016766) 课表")
        )
    }

    @Test
    fun diagnosticJson_doesNotExposeUnrelatedPortalPageText() {
        val json = PortalSnapshot.diagnosticJson("course", "未识别学生 ID")

        assertTrue(json.contains("\"dataStatus\": \"未识别学生 ID\""))
        assertFalse(json.contains("初始化数据"))
    }

    @Test
    fun quickBaseline_ordersAllFourNativeEntries() {
        val baseUrl = "https://example.test/student"
        val items = listOf(
            PortalItem("培养方案", "/program", baseUrl, quick = true, nativeType = "program"),
            PortalItem("成绩", "/grade", baseUrl, quick = true, nativeType = "grade"),
            PortalItem("普通入口", "/other", baseUrl),
            PortalItem("课表", "/schedule", baseUrl, quick = true, nativeType = "schedule"),
            PortalItem("考试", "/exam", baseUrl, quick = true, nativeType = "exam")
        )

        assertEquals(
            listOf("schedule", "grade", "exam", "program"),
            orderedQuickBaselineItems(items).map { it.nativeType }
        )
    }

    @Test
    fun quickBaseline_usesReadableLogCategories() {
        assertEquals("课表", quickBaselineCategory("schedule"))
        assertEquals("成绩", quickBaselineCategory("grade"))
        assertEquals("考试", quickBaselineCategory("exam"))
        assertEquals("培养方案", quickBaselineCategory("program"))
    }

    @Test
    fun quickBaseline_rejectsInitialSkeletonAndAcceptsPopulatedPage() {
        val emptySchedule = MaterialPage(
            title = "我的课表",
            sourceUrl = "https://example.test/schedule",
            choices = emptyList(),
            actions = emptyList(),
            sections = listOf(MaterialSection.Schedule("本学期", "", emptyList()))
        )
        val populatedSchedule = emptySchedule.copy(
            sections = listOf(
                MaterialSection.Schedule(
                    title = "本学期",
                    semesterStartDate = "",
                    days = listOf(
                        ScheduleDay(
                            "星期一",
                            listOf(MaterialCardItem("高等数学", "", "", emptyList()))
                        )
                    )
                )
            )
        )

        assertFalse(quickBaselineHasData(emptySchedule, "schedule"))
        assertTrue(quickBaselineHasData(populatedSchedule, "schedule"))
    }

    @Test
    fun parsedDataJson_exposesTableDataWithoutHtml() {
        val html = """
            <html><body><table class="student-grade-table">
              <tr><th>课程</th><th>成绩</th></tr>
              <tr><td>高等数学</td><td>95</td></tr>
            </table></body></html>
        """.trimIndent()
        val json = PortalSnapshot.parsedDataJson(html, "grade", "student-grade-table")

        assertTrue(json.contains("\"type\": \"grade\""))
        assertTrue(json.contains("高等数学"))
        assertTrue(json.contains("95"))
        assertFalse(json.contains("<table"))
        assertFalse(json.contains("<html"))
    }

    @Test
    fun parsedDataJson_keepsFirstRowWhenTableHasNoHeaderCells() {
        val html = "<table><tr><td>高等数学</td><td>95</td></tr></table>"
        val json = PortalSnapshot.parsedDataJson(html, "grade")

        assertTrue(json.contains("高等数学"))
        assertTrue(json.contains("95"))
        assertTrue(json.contains("\"headers\": []"))
    }

    @Test
    fun parsedDataJson_recognizesTdBasedGradeHeaderWithoutInventingAResult() {
        val html = "<table><tr><td>课程名称</td><td>学分</td><td>成绩</td></tr></table>"
        val json = PortalSnapshot.parsedDataJson(html, "grade")

        assertTrue(json.contains("\"headers\": [\"课程名称\", \"学分\", \"成绩\"]"))
        assertTrue(json.contains("\"rows\": [\n      ]"))
    }

    @Test
    fun courseEntries_acceptsNonEmptyLessonIdList() {
        assertTrue(PortalSnapshot.hasCourseEntries("{\"lessonIds\":[12345],\"lessons\":[]}"))
        assertFalse(PortalSnapshot.hasCourseEntries("{\"lessonIds\":[],\"lessons\":[]}"))
    }

    @Test
    fun portalReadRequest_matchesBrowserHeadersForAjaxData() {
        val request = portalReadRequest(
            url = "https://example.test/course-data",
            referer = "https://example.test/course-table/info/102030",
            ajax = true
        )

        assertTrue(request.header("User-Agent").orEmpty().startsWith("Mozilla/5.0"))
        assertEquals("zh-CN,zh;q=0.9", request.header("Accept-Language"))
        assertEquals(
            "https://example.test/course-table/info/102030",
            request.header("Referer")
        )
        assertEquals("XMLHttpRequest", request.header("X-Requested-With"))
    }

    @Test
    fun parsedDataJson_fallsBackToAnyTableWhenConfiguredClassDiffers() {
        val html = "<table class=\"school-specific\"><tr><th>课程</th></tr><tr><td>大学英语</td></tr></table>"
        val json = PortalSnapshot.parsedDataJson(html, "grade", "student-grade-table")

        assertTrue(json.contains("大学英语"))
        assertTrue(json.contains("\"text\": \"课程 大学英语\""))
    }

    @Test
    fun historyDisplayContent_convertsLegacyHtmlToJson() {
        val displayed = PortalSnapshot.historyDisplayContent("<html><body>旧成绩 88</body></html>")

        assertTrue(displayed.contains("\"type\": \"legacy-html\""))
        assertTrue(displayed.contains("旧成绩 88"))
        assertFalse(displayed.contains("<html"))
    }
}
