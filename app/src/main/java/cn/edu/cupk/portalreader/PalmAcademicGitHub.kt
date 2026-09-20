package cn.edu.cupk.portalreader

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.CookieJar
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.util.concurrent.TimeUnit

object PalmAcademicGitHub {
    const val OWNER = "Genkaim"
    const val REPOSITORY = "palm-academic"
    const val WEB_URL = "https://github.com/$OWNER/$REPOSITORY"
    private const val API_BASE = "https://api.github.com/repos/$OWNER/$REPOSITORY"

    // Never reuse PortalHttp here: its cookie jar contains the user's academic session.
    private val client = OkHttpClient.Builder()
        .cookieJar(CookieJar.NO_COOKIES)
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .callTimeout(30, TimeUnit.SECONDS)
        .build()

    suspend fun repositoryFile(path: String): String = withContext(Dispatchers.IO) {
        require(path.matches(Regex("[A-Za-z0-9._/-]+")) && ".." !in path) { "远程文件路径不安全" }
        get(
            "$API_BASE/contents/$path?ref=main",
            accept = "application/vnd.github.raw+json",
            maxBytes = 2 * 1024 * 1024
        )
    }

    suspend fun latestRelease(): GitHubRelease = withContext(Dispatchers.IO) {
        val root = JSONObject(get("$API_BASE/releases/latest", maxBytes = 1024 * 1024))
        val assets = root.optJSONArray("assets")
        var apkUrl: String? = null
        if (assets != null) {
            for (index in 0 until assets.length()) {
                val asset = assets.getJSONObject(index)
                if (asset.optString("name").endsWith(".apk", ignoreCase = true)) {
                    apkUrl = asset.optString("browser_download_url").takeIf { it.startsWith("https://") }
                    if (apkUrl != null) break
                }
            }
        }
        GitHubRelease(
            tagName = root.getString("tag_name"),
            name = root.optString("name").ifBlank { root.getString("tag_name") },
            notes = root.optString("body"),
            pageUrl = root.getString("html_url"),
            apkUrl = apkUrl,
            publishedAt = root.optString("published_at")
        )
    }

    private fun get(
        url: String,
        accept: String = "application/vnd.github+json",
        maxBytes: Int
    ): String {
        val request = Request.Builder()
            .url(url)
            .header("Accept", accept)
            .header("X-GitHub-Api-Version", "2022-11-28")
            .header("User-Agent", "PalmAcademic/${BuildConfig.VERSION_NAME}")
            .get()
            .build()
        return client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                val message = when (response.code) {
                    404 -> "仓库中暂未发布对应内容"
                    403 -> "GitHub 请求次数受限，请稍后重试"
                    else -> "GitHub 请求失败（${response.code}）"
                }
                error(message)
            }
            val body = response.body ?: error("GitHub 返回内容为空")
            val declaredLength = body.contentLength()
            if (declaredLength > maxBytes) error("远程文件超过大小限制")
            body.string().also { if (it.toByteArray().size > maxBytes) error("远程文件超过大小限制") }
        }
    }
}

data class GitHubRelease(
    val tagName: String,
    val name: String,
    val notes: String,
    val pageUrl: String,
    val apkUrl: String?,
    val publishedAt: String
) {
    fun isNewerThan(currentVersion: String): Boolean =
        compareVersions(tagName.removePrefix("v"), currentVersion.removePrefix("v")) > 0

    private fun compareVersions(left: String, right: String): Int {
        val leftParts = left.substringBefore('-').split('.').map { it.toIntOrNull() ?: 0 }
        val rightParts = right.substringBefore('-').split('.').map { it.toIntOrNull() ?: 0 }
        for (index in 0 until maxOf(leftParts.size, rightParts.size)) {
            val comparison = (leftParts.getOrNull(index) ?: 0).compareTo(rightParts.getOrNull(index) ?: 0)
            if (comparison != 0) return comparison
        }
        return 0
    }
}
