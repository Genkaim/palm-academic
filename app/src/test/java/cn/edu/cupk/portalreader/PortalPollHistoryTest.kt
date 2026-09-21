package cn.edu.cupk.portalreader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PortalPollHistoryTest {
    @Test
    fun preview_makesExamRowsReadable() {
        assertEquals("考试 A\n考试 B", PortalPollHistory.preview("考试 A\u001E考试 B"))
    }

    @Test
    fun difference_includesBeforeAndAfterContent() {
        val difference = PortalPollHistory.difference("旧安排", "新安排")
        assertTrue(difference.contains("更新前：旧安排"))
        assertTrue(difference.contains("更新后：新安排"))
    }

    @Test
    fun difference_withoutStoredPreview_stillShowsCurrentContent() {
        assertEquals("更新后：新数据", PortalPollHistory.difference(null, "新数据"))
    }
}
