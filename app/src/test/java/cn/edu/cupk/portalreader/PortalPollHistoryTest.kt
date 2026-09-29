package cn.edu.cupk.portalreader

import org.junit.Assert.assertEquals
import org.junit.Test

class PortalPollHistoryTest {
    @Test
    fun detail_defaultsToConciseLogFields() {
        val detail = PortalPollHistoryDetail(category = "成绩", summary = "无变化")

        assertEquals("", detail.requestUrl)
        assertEquals("", detail.technicalDetails)
        assertEquals("", detail.previousContent)
        assertEquals("", detail.currentContent)
    }

    @Test
    fun detail_exposesRequestAndNotificationState() {
        val detail = PortalPollHistoryDetail(
            category = "考试",
            summary = "检测到变动",
            changed = true,
            notificationEnabled = true,
            notificationTriggered = true,
            requestUrl = "https://example.test/exam",
            finalUrl = "https://example.test/exam?redirected=1",
            responseCode = 200,
            technicalDetails = "完整解析详情",
            previousContent = "旧数据",
            currentContent = "新数据"
        )
        assertEquals(true, detail.notificationEnabled)
        assertEquals("https://example.test/exam", detail.requestUrl)
        assertEquals("旧数据", detail.previousContent)
        assertEquals("新数据", detail.currentContent)
    }

    @Test
    fun exportedHistory_containsSummaryButOmitsRawDiagnostics() {
        val detail = PortalPollHistoryDetail(
            category = "课表",
            summary = "检测到变动",
            changed = true,
            notificationEnabled = true,
            notificationTriggered = true,
            requestUrl = "https://example.test/request",
            finalUrl = "https://example.test/final",
            responseCode = 200,
            technicalDetails = "解析详情",
            previousContent = "{\"lessons\":[\"旧课程\"]}",
            currentContent = "{\"lessons\":[\"新课程\"]}",
            difference = "当前数据（1 项）：\n• 大学物理B（Ⅱ）｜星期二｜第4-5节｜地点：C9楼I区206｜教师：孙志刚"
        )

        val exported = historyExportText(
            listOf(
                PortalPollHistoryEntry(
                    timestamp = 1_700_000_000_000,
                    status = "检查完成",
                    notificationTriggered = true,
                    details = listOf(detail)
                )
            )
        )

        listOf(
            "课表", "检测到变动", "检查完成", "数据明细", "大学物理B（Ⅱ）",
            "星期二", "第4-5节", "C9楼I区206", "孙志刚"
        ).forEach { expected ->
            assert(exported.contains(expected)) { "导出内容缺少：$expected" }
        }
        listOf(
            "旧课程", "新课程", "https://example.test/request",
            "https://example.test/final", "解析详情", "HTTP 状态：200"
        ).forEach { omitted ->
            assert(!exported.contains(omitted)) { "导出内容不应包含：$omitted" }
        }
    }
}
