package cn.edu.cupk.portalreader

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GitHubReleaseTest {
    private fun release(tag: String) = GitHubRelease(tag, tag, "", "https://example.test", null, "")

    @Test
    fun semanticVersionComparison_detectsNewerRelease() {
        assertTrue(release("v0.3.1").isNewerThan("0.3.0"))
        assertTrue(release("v1.0.0").isNewerThan("0.9.9"))
        assertFalse(release("v0.3.0").isNewerThan("0.3.0"))
        assertFalse(release("v0.2.9").isNewerThan("0.3.0"))
    }
}
