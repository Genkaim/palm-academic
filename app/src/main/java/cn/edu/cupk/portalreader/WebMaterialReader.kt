package cn.edu.cupk.portalreader

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream

data class MaterialPage(
    val title: String,
    val sourceUrl: String,
    val choices: List<MaterialChoice>,
    val actions: List<MaterialPageAction>,
    val sections: List<MaterialSection>
)

data class MaterialChoiceOption(val value: String, val label: String)

data class MaterialChoice(
    val id: String,
    val label: String,
    val value: String,
    val options: List<MaterialChoiceOption>
)

data class MaterialPageAction(val id: String, val label: String, val value: String)

data class MaterialReaderAction(val id: String, val value: String, val token: Int)

data class MaterialCourseSchedule(
    val weeks: String,
    val startSection: String,
    val endSection: String,
    val teacher: String,
    val location: String,
    val startTime: String,
    val endTime: String
)

data class MaterialCardItem(
    val title: String,
    val subtitle: String,
    val accent: String,
    val fields: List<Pair<String, String>>,
    val schedule: MaterialCourseSchedule? = null
)

data class MaterialStatItem(val label: String, val value: String)

data class ScheduleDay(val name: String, val lessons: List<MaterialCardItem>)

data class ProgramModule(
    val id: String,
    val title: String,
    val depth: Int,
    val status: String,
    val requirements: List<String>,
    val headers: List<String>,
    val courses: List<List<String>>,
    val children: List<ProgramModule>
)

sealed interface MaterialSection {
    val title: String

    data class Table(
        override val title: String,
        val headers: List<String>,
        val rows: List<List<String>>
    ) : MaterialSection

    data class Fields(
        override val title: String,
        val fields: List<Pair<String, String>>
    ) : MaterialSection

    data class Text(
        override val title: String,
        val paragraphs: List<String>
    ) : MaterialSection

    data class Links(
        override val title: String,
        val links: List<Pair<String, String>>
    ) : MaterialSection

    data class Schedule(
        override val title: String,
        val semesterStartDate: String,
        val days: List<ScheduleDay>
    ) : MaterialSection

    data class Cards(
        override val title: String,
        val cards: List<MaterialCardItem>
    ) : MaterialSection

    data class Program(
        override val title: String,
        val completedCredits: String,
        val requiredCredits: String,
        val modules: List<ProgramModule>
    ) : MaterialSection

    data class Stats(
        override val title: String,
        val items: List<MaterialStatItem>
    ) : MaterialSection
}

private class MaterialReaderBridge(
    private val onContent: (MaterialPage) -> Unit
) {
    private val mainHandler = Handler(Looper.getMainLooper())

    @JavascriptInterface
    fun onContent(json: String) {
        runCatching { parseMaterialPage(json) }
            .onSuccess { page -> mainHandler.post { onContent(page) } }
    }
}

private fun parseMaterialPage(json: String): MaterialPage {
    val root = JSONObject(json)
    val choices = parseChoices(root.optJSONArray("choices"))
    val actions = parseActions(root.optJSONArray("actions"))
    val sectionsJson = root.optJSONArray("sections")
    val sections = buildList {
        if (sectionsJson == null) return@buildList
        for (index in 0 until sectionsJson.length()) {
            val section = sectionsJson.getJSONObject(index)
            val title = section.optString("title")
            when (section.optString("type")) {
                "schedule" -> {
                    val daysJson = section.optJSONArray("days") ?: continue
                    val days = (0 until daysJson.length()).map { dayIndex ->
                        val day = daysJson.getJSONObject(dayIndex)
                        ScheduleDay(
                            name = day.optString("name"),
                            lessons = parseCards(day.optJSONArray("lessons"))
                        )
                    }
                    add(MaterialSection.Schedule(title, section.optString("semesterStartDate"), days))
                }
                "cards" -> add(MaterialSection.Cards(title, parseCards(section.optJSONArray("cards"))))
                "stats" -> {
                    val itemsJson = section.optJSONArray("items") ?: continue
                    val items = (0 until itemsJson.length()).map { itemIndex ->
                        val item = itemsJson.getJSONObject(itemIndex)
                        MaterialStatItem(item.optString("label"), item.optString("value"))
                    }
                    add(MaterialSection.Stats(title, items))
                }
                "program" -> add(
                    MaterialSection.Program(
                        title = title,
                        completedCredits = section.optString("completedCredits"),
                        requiredCredits = section.optString("requiredCredits"),
                        modules = parseProgramModules(section.optJSONArray("modules"))
                    )
                )
                "table" -> {
                    val headersJson = section.optJSONArray("headers") ?: continue
                    val rowsJson = section.optJSONArray("rows") ?: continue
                    val headers = (0 until headersJson.length()).map { headersJson.optString(it) }
                    val rows = (0 until rowsJson.length()).map { rowIndex ->
                        val row = rowsJson.getJSONArray(rowIndex)
                        (0 until row.length()).map { row.optString(it) }
                    }
                    add(MaterialSection.Table(title, headers, rows))
                }
                "fields" -> {
                    val fieldsJson = section.optJSONArray("fields") ?: continue
                    val fields = (0 until fieldsJson.length()).map { fieldIndex ->
                        val field = fieldsJson.getJSONObject(fieldIndex)
                        field.optString("label") to field.optString("value")
                    }
                    add(MaterialSection.Fields(title, fields))
                }
                "text" -> {
                    val values = section.optJSONArray("paragraphs") ?: continue
                    add(MaterialSection.Text(title, (0 until values.length()).map { values.optString(it) }))
                }
                "links" -> {
                    val linksJson = section.optJSONArray("links") ?: continue
                    val links = (0 until linksJson.length()).map { linkIndex ->
                        val link = linksJson.getJSONObject(linkIndex)
                        link.optString("title") to link.optString("url")
                    }
                    add(MaterialSection.Links(title, links))
                }
            }
        }
    }
    return MaterialPage(
        title = root.optString("title"),
        sourceUrl = root.optString("sourceUrl"),
        choices = choices,
        actions = actions,
        sections = sections
    )
}

private fun parseChoices(array: JSONArray?): List<MaterialChoice> {
    if (array == null) return emptyList()
    return (0 until array.length()).map { index ->
        val choice = array.getJSONObject(index)
        val optionsJson = choice.optJSONArray("options")
        val options = if (optionsJson == null) emptyList() else (0 until optionsJson.length()).map { optionIndex ->
            val option = optionsJson.getJSONObject(optionIndex)
            MaterialChoiceOption(option.optString("value"), option.optString("label"))
        }
        MaterialChoice(
            id = choice.optString("id"),
            label = choice.optString("label"),
            value = choice.optString("value"),
            options = options
        )
    }
}

private fun parseActions(array: JSONArray?): List<MaterialPageAction> {
    if (array == null) return emptyList()
    return (0 until array.length()).map { index ->
        val action = array.getJSONObject(index)
        MaterialPageAction(action.optString("id"), action.optString("label"), action.optString("value"))
    }
}

private fun parseProgramModules(array: JSONArray?): List<ProgramModule> {
    if (array == null) return emptyList()
    return (0 until array.length()).map { index ->
        val module = array.getJSONObject(index)
        val requirementsJson = module.optJSONArray("requirements")
        val headersJson = module.optJSONArray("headers")
        val coursesJson = module.optJSONArray("courses")
        ProgramModule(
            id = module.optString("id"),
            title = module.optString("title"),
            depth = module.optInt("depth", 1),
            status = module.optString("status"),
            requirements = if (requirementsJson == null) emptyList() else
                (0 until requirementsJson.length()).map { requirementsJson.optString(it) },
            headers = if (headersJson == null) emptyList() else
                (0 until headersJson.length()).map { headersJson.optString(it) },
            courses = if (coursesJson == null) emptyList() else (0 until coursesJson.length()).map { rowIndex ->
                val row = coursesJson.getJSONArray(rowIndex)
                (0 until row.length()).map { row.optString(it) }
            },
            children = parseProgramModules(module.optJSONArray("children"))
        )
    }
}

private fun parseCards(array: org.json.JSONArray?): List<MaterialCardItem> {
    if (array == null) return emptyList()
    return (0 until array.length()).map { index ->
        val item = array.getJSONObject(index)
        val fieldsJson = item.optJSONArray("fields")
        val fields = if (fieldsJson == null) emptyList() else (0 until fieldsJson.length()).map { fieldIndex ->
            val field = fieldsJson.getJSONObject(fieldIndex)
            field.optString("label") to field.optString("value")
        }
        val scheduleJson = item.optJSONObject("schedule")
        val schedule = scheduleJson?.let { value ->
            MaterialCourseSchedule(
                weeks = value.optString("weeks"),
                startSection = value.optString("startSection"),
                endSection = value.optString("endSection"),
                teacher = value.optString("teacher"),
                location = value.optString("location"),
                startTime = value.optString("startTime"),
                endTime = value.optString("endTime")
            )
        }
        MaterialCardItem(
            title = item.optString("title"),
            subtitle = item.optString("subtitle"),
            accent = item.optString("accent"),
            fields = fields,
            schedule = schedule
        )
    }
}

private val safeReadPostMarkers = listOf(
    "/search", "/query", "/list", "/page", "/get-data", "/find",
    "/preview", "/statistics", "/options"
)

private fun readRequestAllowed(request: WebResourceRequest): Boolean {
    if (request.method.equals("GET", true) || request.method.equals("HEAD", true)) return true
    val path = request.url.path.orEmpty().lowercase()
    return request.method.equals("POST", true) && safeReadPostMarkers.any(path::contains)
}

private fun blockedResponse() = WebResourceResponse(
    "application/json",
    "UTF-8",
    403,
    "Blocked",
    mapOf("Cache-Control" to "no-store"),
    ByteArrayInputStream("{}".toByteArray())
)

private data class ReaderRenderState(var refreshToken: Int, var actionToken: Int)

@SuppressLint("SetJavaScriptEnabled", "JavascriptInterface")
@Composable
fun WebMaterialReader(
    url: String,
    adapterScript: String,
    schoolConfigJson: String,
    refreshToken: Int,
    action: MaterialReaderAction?,
    modifier: Modifier = Modifier,
    onLoading: (Boolean) -> Unit,
    onContent: (MaterialPage) -> Unit,
    onError: (String) -> Unit,
    onSessionExpired: () -> Unit
) {
    AndroidView(
        modifier = modifier,
        factory = { context ->
            WebView(context).apply {
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                setBackgroundColor(portalViewColors(context).webBackground)
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.cacheMode = WebSettings.LOAD_DEFAULT
                settings.blockNetworkImage = true
                settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                configurePortalWebDarkening(settings, PortalThemePreferences.isDark(context))
                addJavascriptInterface(MaterialReaderBridge(onContent), "PalmAcademicBridge")
                webViewClient = object : WebViewClient() {
                    private fun isLoginPage(pageUrl: String?): Boolean =
                        pageUrl != null && Uri.parse(pageUrl).path?.trimEnd('/')?.endsWith("/login") == true

                    private fun injectReader(view: WebView) {
                        val hostApi = """
                            window.PalmAcademicHost = {
                              apiVersion: 1,
                              schoolConfig: $schoolConfigJson,
                              publish: function(payload) {
                                PalmAcademicBridge.onContent(JSON.stringify(payload));
                              }
                            };
                        """.trimIndent()
                        view.evaluateJavascript(hostApi) {
                            view.evaluateJavascript(adapterScript, null)
                        }
                    }

                    override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                        onLoading(true)
                    }

                    override fun onPageCommitVisible(view: WebView, url: String?) {
                        if (isLoginPage(url)) {
                            onSessionExpired()
                            return
                        }
                        // Start observing the DOM as soon as it is drawable instead of waiting
                        // for images and other nonessential subresources to finish.
                        injectReader(view)
                    }

                    override fun onPageFinished(view: WebView, finishedUrl: String?) {
                        if (isLoginPage(finishedUrl)) {
                            onSessionExpired()
                            return
                        }
                        PortalSessionStore.captureFromWebView()
                        // Fallback for WebView implementations that do not issue commit-visible.
                        injectReader(view)
                    }

                    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                        request.url.scheme != "https" || !readRequestAllowed(request)

                    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                        if (request.url.scheme != "https" || !readRequestAllowed(request)) return blockedResponse()
                        return super.shouldInterceptRequest(view, request)
                    }

                    override fun onReceivedError(
                        view: WebView,
                        request: WebResourceRequest,
                        error: android.webkit.WebResourceError
                    ) {
                        if (request.isForMainFrame) {
                            onLoading(false)
                            onError(error.description?.toString().orEmpty().ifBlank { "内容加载失败" })
                        }
                    }
                }
                tag = ReaderRenderState(refreshToken, action?.token ?: -1)
                val reader = this
                if (!PortalSessionStore.restoreToWebView { reader.loadUrl(url) }) {
                    loadUrl(url)
                }
            }
        },
        update = { webView ->
            val state = webView.tag as ReaderRenderState
            if (state.refreshToken != refreshToken) {
                state.refreshToken = refreshToken
                webView.reload()
            }
            if (action != null && state.actionToken != action.token) {
                state.actionToken = action.token
                val script = "window.PalmAcademicAdapter && window.PalmAcademicAdapter.perform(" +
                    JSONObject.quote(action.id) + "," + JSONObject.quote(action.value) + ");"
                webView.evaluateJavascript(script, null)
            }
        }
    )
}
