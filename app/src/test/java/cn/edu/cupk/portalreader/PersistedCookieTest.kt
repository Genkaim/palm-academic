package cn.edu.cupk.portalreader

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PersistedCookieTest {

    private fun tgc() = PersistedCookie(
        name = "TGC",
        value = "TGT-123",
        domain = "cas.cupk.edu.cn",
        path = "/cas",
        secure = true,
        httpOnly = true,
        hostOnly = true,
        expiresAt = Long.MAX_VALUE
    )

    private fun portalSession() = PersistedCookie(
        name = "SESSION",
        value = "portal-session",
        domain = "portal.cupk.edu.cn",
        path = "/portal",
        secure = true,
        httpOnly = true,
        hostOnly = true,
        expiresAt = Long.MAX_VALUE
    )

    @Test
    fun tgc_is_only_sent_to_cas_host() {
        val tgc = tgc()
        assertTrue(tgc.matches("cas.cupk.edu.cn", "/cas/login", https = true))
        // 核心回归：CAS 票据绝不能随门户请求发出，反之亦然。
        assertFalse(tgc.matches("portal.cupk.edu.cn", "/portal/r/w", https = true))
        assertFalse(tgc.matches("evil.example.com", "/cas", https = true))
    }

    @Test
    fun portal_session_scoped_to_portal_path_and_scheme() {
        val session = portalSession()
        assertTrue(session.matches("portal.cupk.edu.cn", "/portal/r/w?cmd=x", https = true))
        assertFalse(session.matches("cas.cupk.edu.cn", "/cas/login", https = true))
        assertFalse(session.matches("portal.cupk.edu.cn", "/portal/r/w", https = false))
        // /portal 的 cookie 不发给站点其它路径。
        assertFalse(session.matches("portal.cupk.edu.cn", "/other", https = true))
    }

    @Test
    fun domain_cookie_covers_subdomains() {
        val wildcard = PersistedCookie(
            name = "K", value = "V", domain = "cupk.edu.cn", path = "/",
            secure = false, httpOnly = false, hostOnly = false, expiresAt = Long.MAX_VALUE
        )
        assertTrue(wildcard.matches("www.cupk.edu.cn", "/", https = true))
        assertTrue(wildcard.matches("cupk.edu.cn", "/", https = false))
        assertFalse(wildcard.matches("evilcupk.edu.cn", "/", https = true))
    }

    @Test
    fun json_round_trip_preserves_scope() {
        val restored = PersistedCookie.fromJson(tgc().toJson())
        assertEquals(tgc(), restored)
    }

    @Test
    fun json_defaults_are_host_only_with_root_path() {
        val parsed = PersistedCookie.fromJson(
            JSONObject("""{"name":"a","value":"b","domain":"host.example"}""")
        )
        assertTrue(parsed.hostOnly)
        assertEquals("/", parsed.path)
        assertEquals(Long.MAX_VALUE, parsed.expiresAt)
    }
}
