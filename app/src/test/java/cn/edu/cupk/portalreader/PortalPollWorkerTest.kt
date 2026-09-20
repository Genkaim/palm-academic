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
}
