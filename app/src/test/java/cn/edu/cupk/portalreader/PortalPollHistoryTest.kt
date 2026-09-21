package cn.edu.cupk.portalreader

import org.junit.Assert.assertEquals
import org.junit.Test

class PortalPollHistoryTest {
    @Test
    fun detail_keepsCompleteResponseWithoutTruncation() {
        val fullResponse = "原始响应".repeat(2_000)
        val detail = PortalPollHistoryDetail(
            category = "成绩",
            summary = "无变化",
            currentContent = fullResponse
        )
        assertEquals(fullResponse, detail.currentContent)
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
}
