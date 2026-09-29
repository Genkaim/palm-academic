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
    fun monitorDefinition_prefersLatestSemesterOptionOverStalePageVariable() {
        val monitor = PortalMonitorDefinition(
            coursePagePath = "/course-table",
            courseDataPathTemplate = "/course-data?semester={semesterId}",
            gradeDataPathTemplate = "/grade",
            examDataPathTemplate = "/exam",
            semesterIdPatterns = listOf("var\\s+semesterId\\s*=\\s*(\\d+)"),
            studentIdPatterns = emptyList()
        )
        val page = """
            <select id="allSemesters">
              <option value="1">2017-2018学年秋季学期</option>
              <option value="95">2025-2026学年秋季学期</option>
              <option value="102">2025-2026学年春季学期</option>
            </select>
            <script>var semesterId = 1;</script>
        """.trimIndent()

        assertEquals("102", monitor.extractSemesterId(page))
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
        assertTrue(PortalSnapshot.hasCourseEntries("{\"data\":[{\"name\":\"高等数学\"}]}"))
    }

    @Test
    fun courseSnapshot_ignoresCurrentWeekButKeepsScheduleWeeks() {
        val first = PortalSnapshot.courseDataJson(
            """{"currentWeek":5,"weekIndices":[1,2,3],"lessons":[]}""",
            "102"
        )
        val second = PortalSnapshot.courseDataJson(
            """{"currentWeek":6,"weekIndices":[1,2,3],"lessons":[]}""",
            "102"
        )

        assertEquals(PortalSnapshot.stableHash(first), PortalSnapshot.stableHash(second))
        assertFalse(first.contains("currentWeek"))
        assertTrue(first.contains("weekIndices"))
    }

    @Test
    fun courseSnapshot_ignoresMetadataCountsAndUnorderedRecruitTypes() {
        val first = PortalSnapshot.courseDataJson(
            """{
                "lessonIds":[321124],
                "lessons":[{
                    "id":321124,
                    "courseName":"大学物理B（Ⅱ）",
                    "courseStdCount":2684,
                    "openDepartment":{"recruitTypeSet":["POSTGRADUATE","UNDERGRADUATE","DOCTOR"]},
                    "scheduleGroups":[{
                        "weekday":2,"startUnit":4,"endUnit":5,"weeks":[15,1,2],
                        "room":"C9楼I区206",
                        "teacher":{"name":"孙志刚","department":{"recruitTypeSet":["UNDERGRADUATE","DOCTOR"]}}
                    }]
                }]
            }""".trimIndent(),
            "102"
        )
        val second = PortalSnapshot.courseDataJson(
            """{
                "lessonIds":[321124],
                "lessons":[{
                    "id":321124,
                    "courseName":"大学物理B（Ⅱ）",
                    "courseStdCount":2687,
                    "openDepartment":{"recruitTypeSet":["DOCTOR","POSTGRADUATE","UNDERGRADUATE"]},
                    "scheduleGroups":[{
                        "weekday":2,"startUnit":4,"endUnit":5,"weeks":[2,1,15],
                        "room":"C9楼I区206",
                        "teacher":{"name":"孙志刚","department":{"recruitTypeSet":["DOCTOR","UNDERGRADUATE"]}}
                    }]
                }]
            }""".trimIndent(),
            "102"
        )

        assertEquals(PortalSnapshot.stableHash(first), PortalSnapshot.stableHash(second))
        assertFalse(first.contains("courseStdCount"))
        assertFalse(first.contains("recruitTypeSet"))
    }

    @Test
    fun courseSnapshot_detectsActualScheduleChanges() {
        val first = PortalSnapshot.courseDataJson(
            """{"lessonIds":[1],"lessons":[{"id":1,"courseName":"高等数学","scheduleGroups":[{"weekday":1,"startUnit":3,"endUnit":4,"room":"A101","teacher":{"name":"张老师"}}]}]}""",
            "102"
        )
        val second = PortalSnapshot.courseDataJson(
            """{"lessonIds":[1],"lessons":[{"id":1,"courseName":"高等数学","scheduleGroups":[{"weekday":1,"startUnit":3,"endUnit":4,"room":"B305","teacher":{"name":"张老师"}}]}]}""",
            "102"
        )

        assertFalse(PortalSnapshot.stableHash(first) == PortalSnapshot.stableHash(second))
    }

    @Test
    fun courseLogRows_keepConcreteScheduleFieldsAndDropMetadata() {
        val rows = PortalLogDetails.courseRows(
            """{
                "lessonIds":[321124],
                "lessons":[{
                    "id":321124,
                    "courseName":"大学物理B（Ⅱ）",
                    "courseStdCount":2687,
                    "scheduleGroups":[{
                        "weekday":2,
                        "startUnit":4,
                        "endUnit":5,
                        "weeks":[15,1,2],
                        "room":"C9楼I区206",
                        "teacher":{"name":"孙志刚"}
                    }]
                }]
            }""".trimIndent()
        )

        assertEquals(1, rows.size)
        listOf("大学物理B（Ⅱ）", "321124", "星期二", "第4-5节", "第1-2、15周", "C9楼I区206", "孙志刚")
            .forEach { value -> assertTrue(rows.single().contains(value)) }
        assertFalse(rows.single().contains("2687"))
    }

    @Test
    fun materialGradeRows_includeCourseScoreCreditsAndGpa() {
        val rows = PortalLogDetails.materialRows(
            """{
                "title":"课程成绩",
                "sourceUrl":"https://example.test/grade",
                "choices":[],
                "actions":[],
                "sections":[
                    {"type":"stats","title":"GPA与排名","items":[{"label":"GPA","value":"3.72"}]},
                    {"type":"cards","title":"2025-2026-1","cards":[{
                        "title":"大学物理B（Ⅱ）",
                        "subtitle":"PHYS102",
                        "accent":"88",
                        "fields":[{"label":"学分","value":"4"},{"label":"绩点","value":"3.8"}]
                    }]}
                ]
            }""".trimIndent(),
            "grade"
        )

        assertTrue(rows.any { it.contains("GPA：3.72") })
        assertTrue(rows.any {
            listOf("大学物理B（Ⅱ）", "PHYS102", "成绩：88", "学分：4", "绩点：3.8")
                .all(it::contains)
        })
    }

    @Test
    fun logDescription_showsConcreteBeforeAndAfterRows() {
        val previous = PortalLogDetails.encode(listOf("高等数学｜地点：A101｜教师：张老师"))
        val current = listOf("高等数学｜地点：B305｜教师：张老师")

        val detail = PortalLogDetails.describe(previous, current, changed = true)

        assertTrue(detail.contains("新增或变更后"))
        assertTrue(detail.contains("B305"))
        assertTrue(detail.contains("移除或变更前"))
        assertTrue(detail.contains("A101"))
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

    @Test
    fun homeChangeNotice_returnsNewestSupportedUnreadChange() {
        val entries = listOf(
            pollHistoryEntry(200L, "成绩"),
            pollHistoryEntry(100L, "课表")
        )

        val notice = latestUnreadPortalChange(entries) { 0L }

        assertEquals("成绩", notice?.category)
        assertEquals("grade", notice?.nativeType)
        assertEquals(200L, notice?.timestamp)
    }

    @Test
    fun homeChangeNotice_advancesAfterCurrentCategoryIsAcknowledged() {
        val entries = listOf(
            pollHistoryEntry(200L, "成绩"),
            pollHistoryEntry(100L, "考试")
        )

        val notice = latestUnreadPortalChange(entries) { nativeType ->
            if (nativeType == "grade") 200L else 0L
        }

        assertEquals("考试", notice?.category)
        assertEquals("exam", notice?.nativeType)
    }

    private fun pollHistoryEntry(timestamp: Long, category: String) = PortalPollHistoryEntry(
        timestamp = timestamp,
        status = "完成",
        notificationTriggered = true,
        details = listOf(
            PortalPollHistoryDetail(
                category = category,
                summary = "$category 发生变化",
                changed = true,
                notificationTriggered = true
            )
        )
    )
}
