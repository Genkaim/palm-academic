package cn.edu.cupk.portalreader

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

data class SchoolOption(val id: String, val name: String)
data class SchoolRefreshResult(val schoolCount: Int, val downloadedFileCount: Int)

private data class SchoolProfile(
    val id: String,
    val name: String,
    val origin: String,
    val definitionAsset: String,
    val readerConfig: JSONObject
)

private data class SchoolIndex(
    val builtIn: List<SchoolProfile>,
    val configVersion: Int
)

object PortalConfig {
    val ORIGIN: String
        get() = if (BuildConfig.LOCAL_MOCK_ENABLED) BuildConfig.PORTAL_ORIGIN
        else SchoolAdapterRepository.activeOrigin()
    val BASE: String get() = "$ORIGIN/student"
    val LOGIN: String get() = "$BASE/login"
    val HOME: String get() = "$BASE/home"
    val COURSE_TABLE: String get() = "$BASE/for-std/course-table"
    val GRADE: String get() = "$BASE/for-std/grade/sheet"
    val EXAM: String get() = "$BASE/for-std/exam-arrange"
}

data class PortalItem(
    val title: String,
    val path: String,
    val baseUrl: String,
    val quick: Boolean = false,
    val nativeType: String? = null
) {
    val url: String get() = if (path.startsWith("http")) path else baseUrl.trimEnd('/') + path
}

data class PortalGroup(val title: String, val items: List<PortalItem>)

data class PortalMonitorDefinition(
    val coursePagePath: String,
    val courseDataPathTemplate: String,
    val gradeDataPathTemplate: String,
    val examDataPathTemplate: String,
    val semesterIdPatterns: List<String>,
    val studentIdPatterns: List<String>
) {
    fun url(baseUrl: String, path: String): String =
        if (path.startsWith("https://")) path else baseUrl.trimEnd('/') + "/" + path.trimStart('/')

    fun coursePageUrl(baseUrl: String): String = url(baseUrl, coursePagePath)

    fun courseDataUrl(baseUrl: String, semesterId: String, studentId: String): String =
        dataUrl(baseUrl, courseDataPathTemplate, semesterId, studentId)

    fun gradeDataUrl(baseUrl: String, semesterId: String, studentId: String): String =
        dataUrl(baseUrl, gradeDataPathTemplate, semesterId, studentId)

    fun examDataUrl(baseUrl: String, semesterId: String, studentId: String): String =
        dataUrl(baseUrl, examDataPathTemplate, semesterId, studentId)

    private fun dataUrl(
        baseUrl: String,
        template: String,
        semesterId: String,
        studentId: String
    ): String = url(
        baseUrl,
        template.replace("{semesterId}", semesterId).replace("{studentId}", studentId)
    )

    fun extractSemesterId(page: String): String? = semesterIdPatterns.firstNotNullOfOrNull { pattern ->
        runCatching { Regex(pattern, RegexOption.DOT_MATCHES_ALL) }.getOrNull()
            ?.find(page)?.groupValues?.getOrNull(1)
    }

    fun extractStudentId(pageAndUrl: String): String? = studentIdPatterns.firstNotNullOfOrNull { pattern ->
        runCatching { Regex(pattern, RegexOption.DOT_MATCHES_ALL) }.getOrNull()
            ?.find(pageAndUrl)?.groupValues?.getOrNull(1)
    }
}

data class SchoolDefinition(
    val id: String,
    val name: String,
    val baseUrl: String,
    val adapterAsset: String,
    val readerConfigJson: String,
    val fallbackUnitTimes: Map<String, Pair<String, String>>,
    val groups: List<PortalGroup>,
    val monitor: PortalMonitorDefinition
) {
    val quickItems: List<PortalItem> get() = groups.flatMap { it.items }.filter { it.quick }
}

/** Loads the selected university profile while keeping the renderer university-neutral. */
object SchoolAdapterRepository {
    private const val PREFS = "school_selection"
    private const val KEY_ACTIVE_SCHOOL = "active_school"
    private const val INDEX_ASSET = "schools/index.json"
    private const val REMOTE_REPOSITORY_ROOT = "app/src/main/assets"
    private const val REMOTE_CACHE_DIRECTORY = "remote-school-adapters"
    private const val DEFAULT_SCHOOL_ID = "cupk"
    private const val DEFAULT_ORIGIN = "https://eams.cupk.edu.cn"
    private val EMAIL_PATTERN = Regex("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$")

    @Volatile
    private var selectedSchoolId = DEFAULT_SCHOOL_ID
    @Volatile
    private var profiles: List<SchoolProfile> = emptyList()

    fun initialize(context: Context) {
        profiles = readProfiles(context)
        val saved = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_ACTIVE_SCHOOL, DEFAULT_SCHOOL_ID)
        selectedSchoolId = saved?.takeIf { id -> profiles.any { it.id == id } } ?: DEFAULT_SCHOOL_ID
    }

    fun options(context: Context): List<SchoolOption> {
        ensureInitialized(context)
        return profiles.map { SchoolOption(it.id, it.name) }
    }

    fun activeSchoolId(): String = selectedSchoolId

    fun activeOrigin(): String =
        profiles.firstOrNull { it.id == selectedSchoolId }?.origin ?: DEFAULT_ORIGIN

    fun activeName(context: Context): String {
        ensureInitialized(context)
        return activeProfile().name
    }

    fun select(context: Context, schoolId: String): Boolean {
        ensureInitialized(context)
        if (profiles.none { it.id == schoolId } || selectedSchoolId == schoolId) return false
        selectedSchoolId = schoolId
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_ACTIVE_SCHOOL, schoolId)
            .commit()
        PortalNotificationPreferences.clearSnapshots(context)
        return true
    }

    fun load(context: Context): SchoolDefinition {
        ensureInitialized(context)
        val profile = activeProfile()
        val root = readJsonConfig(context, profile.definitionAsset)
        val baseUrl = if (BuildConfig.LOCAL_MOCK_ENABLED) {
            PortalConfig.BASE
        } else {
            root.optString("baseUrl").ifBlank { "${profile.origin}/student" }.trimEnd('/')
        }
        val monitorJson = root.optJSONObject("monitor") ?: JSONObject()
        val groupsJson = root.getJSONArray("groups")
        val groups = buildList {
            for (groupIndex in 0 until groupsJson.length()) {
                val groupJson = groupsJson.getJSONObject(groupIndex)
                val itemsJson = groupJson.getJSONArray("items")
                val items = buildList {
                    for (itemIndex in 0 until itemsJson.length()) {
                        val item = itemsJson.getJSONObject(itemIndex)
                        add(
                            PortalItem(
                                title = item.getString("title"),
                                path = item.getString("path"),
                                baseUrl = baseUrl,
                                quick = item.optBoolean("quick", false),
                                nativeType = item.optString("nativeType").takeIf(String::isNotBlank)
                            )
                        )
                    }
                }
                add(PortalGroup(groupJson.getString("title"), items))
            }
        }
        return SchoolDefinition(
            id = profile.id,
            name = profile.name,
            baseUrl = baseUrl,
            adapterAsset = root.getString("readerAdapter"),
            readerConfigJson = profile.readerConfig.toString(),
            fallbackUnitTimes = parseDefaultUnitTimes(profile.readerConfig),
            groups = groups,
            monitor = PortalMonitorDefinition(
                coursePagePath = monitorJson.optString("coursePagePath")
                    .ifBlank { monitorJson.optString("coursePath", "/for-std/course-table") },
                courseDataPathTemplate = monitorJson.optString("courseDataPathTemplate")
                    .ifBlank {
                        "/for-std/course-table/get-data" +
                            "?bizTypeId=2&semesterId={semesterId}&dataId={studentId}" +
                            "&searchTeachingSyllabus=true"
                    },
                gradeDataPathTemplate = monitorJson.optString("gradeDataPathTemplate")
                    .ifBlank { monitorJson.optString("gradePath", "/for-std/grade/sheet") },
                examDataPathTemplate = monitorJson.optString("examDataPathTemplate")
                    .ifBlank { monitorJson.optString("examPath", "/for-std/exam-arrange") },
                semesterIdPatterns = monitorJson.optJSONArray("semesterIdPatterns")?.let { patterns ->
                    (0 until patterns.length()).map(patterns::getString)
                }.orEmpty().ifEmpty {
                    listOf(
                        "currentSemester\\s*=.*?[\"']?id[\"']?\\s*:\\s*(\\d+)",
                        "var\\s+semesterId\\s*=\\s*(\\d+)",
                        "[\"']semesterId[\"']\\s*:\\s*[\"']?(\\d+)"
                    )
                },
                studentIdPatterns = monitorJson.optJSONArray("studentIdPatterns")?.let { patterns ->
                    (0 until patterns.length()).map(patterns::getString)
                }.orEmpty().ifEmpty {
                    listOf(
                        "/for-std/course-table/info/(\\d+)",
                        "[\"']studentId[\"']\\s*:\\s*[\"']?(\\d+)",
                        "[\"']dataId[\"']\\s*:\\s*[\"']?(\\d+)"
                    )
                }
            )
        )
    }

    fun readAdapterScript(context: Context, assetPath: String): String =
        readConfiguredText(context, assetPath)

    suspend fun refreshFromGitHub(context: Context): Result<SchoolRefreshResult> =
        withContext(Dispatchers.IO) {
            runCatching {
                val appContext = context.applicationContext
                val indexText = PalmAcademicGitHub.repositoryFile("$REMOTE_REPOSITORY_ROOT/$INDEX_ASSET")
                val remoteIndex = parseIndex(indexText)
                require(remoteIndex.builtIn.isNotEmpty()) { "远程内置学校列表为空" }

                val downloaded = linkedMapOf<String, String>()
                remoteIndex.builtIn.map { it.definitionAsset }.distinct().forEach { definitionPath ->
                    requireSafeAssetPath(definitionPath, "schools/", ".json")
                    val definitionText = PalmAcademicGitHub.repositoryFile(
                        "$REMOTE_REPOSITORY_ROOT/$definitionPath"
                    )
                    val definition = JSONObject(definitionText)
                    validateDefinition(definition)
                    downloaded[definitionPath] = definitionText

                    val adapterPath = definition.getString("readerAdapter")
                    requireSafeAssetPath(adapterPath, "adapters/", ".js")
                    downloaded[adapterPath] = PalmAcademicGitHub.repositoryFile(
                        "$REMOTE_REPOSITORY_ROOT/$adapterPath"
                    )
                }

                val cacheRoot = File(appContext.filesDir, REMOTE_CACHE_DIRECTORY)
                downloaded.forEach { (path, content) -> writeRemoteFile(cacheRoot, path, content) }
                // Commit the validated index last so a partial download never becomes active.
                writeRemoteFile(
                    cacheRoot,
                    INDEX_ASSET,
                    indexJson(remoteIndex)
                )

                profiles = readProfiles(appContext)
                if (profiles.none { it.id == selectedSchoolId }) {
                    selectedSchoolId = profiles.firstOrNull { it.id == DEFAULT_SCHOOL_ID }?.id
                        ?: profiles.first().id
                    appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                        .edit().putString(KEY_ACTIVE_SCHOOL, selectedSchoolId).commit()
                }
                SchoolRefreshResult(profiles.size, downloaded.size + 1)
            }
        }

    private fun ensureInitialized(context: Context) {
        if (profiles.isEmpty()) initialize(context.applicationContext)
    }

    private fun activeProfile(): SchoolProfile =
        profiles.firstOrNull { it.id == selectedSchoolId }
            ?: profiles.firstOrNull { it.id == DEFAULT_SCHOOL_ID }
            ?: error("学校配置为空")

    private fun readProfiles(context: Context): List<SchoolProfile> {
        return currentIndex(context).builtIn
    }

    private fun currentIndex(context: Context): SchoolIndex {
        val bundled = context.assets.open(INDEX_ASSET).bufferedReader().use {
            parseIndex(it.readText())
        }
        val cached = remoteFile(context, INDEX_ASSET)
        if (cached.isFile) runCatching {
            val cachedText = cached.readText()
            if (JSONObject(cachedText).optInt("schemaVersion") == 2) {
                val cachedIndex = parseIndex(cachedText)
                return if (bundled.configVersion > cachedIndex.configVersion) {
                    bundled
                } else {
                    cachedIndex
                }
            }
        }
        return bundled
    }

    private fun parseIndex(text: String): SchoolIndex {
        val root = JSONObject(text)
        val version = root.optInt("schemaVersion", 0)
        val builtInArray: JSONArray
        when (version) {
            1 -> {
                builtInArray = root.optJSONArray("schools") ?: JSONArray()
            }
            2 -> {
                builtInArray = root.optJSONArray("builtIn") ?: JSONArray()
            }
            else -> error("不支持的学校配置版本")
        }
        val builtIn = parseProfileArray(builtInArray)
        require(builtIn.map { it.id }.distinct().size == builtIn.size) {
            "内置学校 id 重复"
        }
        return SchoolIndex(builtIn, root.optInt("configVersion", 1))
    }

    private fun parseProfileArray(array: JSONArray): List<SchoolProfile> =
        (0 until array.length()).map { parseProfile(array.getJSONObject(it)) }

    private fun parseProfile(item: JSONObject): SchoolProfile {
        val id = item.getString("id")
        val origin = item.getString("origin").trimEnd('/')
        val definitionAsset = item.getString("definitionAsset")
        require(id.matches(Regex("[a-z0-9-]+"))) { "学校 id 格式无效" }
        require(item.getString("name").isNotBlank()) { "学校名称为空" }
        require(origin.startsWith("https://")) { "学校地址必须使用 HTTPS" }
        requireSafeAssetPath(definitionAsset, "schools/", ".json")
        return SchoolProfile(
            id = id,
            name = item.getString("name"),
            origin = origin,
            definitionAsset = definitionAsset,
            readerConfig = item.optJSONObject("readerConfig") ?: JSONObject()
        )
    }

    private fun indexJson(index: SchoolIndex): String = JSONObject().apply {
        put("schemaVersion", 2)
        put("configVersion", index.configVersion)
        put("builtIn", JSONArray().apply { index.builtIn.forEach { put(it.toJson()) } })
        put("imported", JSONArray())
    }.toString(2)

    private fun SchoolProfile.toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("name", name)
        put("origin", origin)
        put("definitionAsset", definitionAsset)
        put("readerConfig", readerConfig)
    }

    private fun readJsonConfig(context: Context, assetPath: String): JSONObject {
        val remote = remoteFile(context, assetPath)
        if (remote.isFile) {
            runCatching { return JSONObject(remote.readText()).also(::validateDefinition) }
        }
        return context.assets.open(assetPath).bufferedReader().use {
            JSONObject(it.readText()).also(::validateDefinition)
        }
    }

    private fun readConfiguredText(context: Context, assetPath: String): String {
        val remote = remoteFile(context, assetPath)
        if (remote.isFile) return remote.readText()
        return context.assets.open(assetPath).bufferedReader().use { it.readText() }
    }

    private fun validateDefinition(root: JSONObject) {
        require(root.optInt("schemaVersion", 0) == 1) { "不支持的学校定义版本" }
        require(root.has("groups")) { "学校定义缺少 groups" }
        require(root.optString("baseUrl").startsWith("https://")) { "学校 baseUrl 必须使用 HTTPS" }
        val author = root.optJSONObject("author")
            ?: error("学校定义缺少 author")
        require(author.optString("name").isNotBlank()) { "学校定义缺少作者名称" }
        require(EMAIL_PATTERN.matches(author.optString("email"))) { "学校定义中的作者邮箱无效" }
        requireSafeAssetPath(root.getString("readerAdapter"), "adapters/", ".js")
        val monitor = root.optJSONObject("monitor") ?: error("学校定义缺少 monitor")
        listOf(
            "coursePagePath",
            "courseDataPathTemplate",
            "gradeDataPathTemplate",
            "examDataPathTemplate"
        ).forEach { key ->
            val path = monitor.optString(key)
            require(path.startsWith("/") || path.startsWith("https://")) { "monitor.$key 路径无效" }
        }
        require("{semesterId}" in monitor.getString("courseDataPathTemplate")) {
            "monitor.courseDataPathTemplate 缺少 {semesterId}"
        }
        listOf("semesterIdPatterns", "studentIdPatterns").forEach { key ->
            monitor.optJSONArray(key)?.let { patterns ->
                require(patterns.length() > 0) { "$key 不能为空" }
                for (index in 0 until patterns.length()) Regex(patterns.getString(index))
            }
        }
        validateFourQuickEntries(root)
    }

    private fun validateFourQuickEntries(root: JSONObject) {
        val quickTypes = buildList {
            val groups = root.getJSONArray("groups")
            for (groupIndex in 0 until groups.length()) {
                val items = groups.getJSONObject(groupIndex).getJSONArray("items")
                for (itemIndex in 0 until items.length()) {
                    val item = items.getJSONObject(itemIndex)
                    if (item.optBoolean("quick", false)) {
                        add(item.optString("nativeType"))
                    }
                }
            }
        }
        val required = setOf("schedule", "grade", "exam", "program")
        require(quickTypes.size == required.size && quickTypes.toSet() == required) {
            "学校定义必须各提供一个 schedule、grade、exam、program 快捷入口"
        }
    }

    private fun requireSafeAssetPath(path: String, prefix: String, suffix: String) {
        require(
            path.startsWith(prefix) && path.endsWith(suffix) && ".." !in path &&
                path.matches(Regex("[A-Za-z0-9._/-]+"))
        ) { "远程配置文件路径无效：$path" }
    }

    private fun remoteFile(context: Context, assetPath: String): File =
        File(File(context.filesDir, REMOTE_CACHE_DIRECTORY), assetPath)

    private fun writeRemoteFile(cacheRoot: File, assetPath: String, content: String) {
        val target = File(cacheRoot, assetPath)
        val rootPath = cacheRoot.canonicalFile.toPath()
        require(target.canonicalFile.toPath().startsWith(rootPath)) { "远程配置写入路径无效" }
        target.parentFile?.mkdirs()
        val temporary = File(target.parentFile, "${target.name}.tmp")
        temporary.writeText(content)
        if (target.exists() && !target.delete()) error("无法替换旧配置：$assetPath")
        if (!temporary.renameTo(target)) error("无法保存远程配置：$assetPath")
    }

    private fun parseDefaultUnitTimes(config: JSONObject): Map<String, Pair<String, String>> {
        val profiles = config.optJSONArray("scheduleProfiles") ?: return emptyMap()
        val defaultProfile = (0 until profiles.length())
            .map(profiles::getJSONObject)
            .firstOrNull { it.optString("locationPattern").isBlank() }
            ?: profiles.optJSONObject(0)
            ?: return emptyMap()
        val times = defaultProfile.optJSONObject("unitTimes") ?: return emptyMap()
        return times.keys().asSequence().mapNotNull { section ->
            val range = times.optJSONArray(section) ?: return@mapNotNull null
            section to (range.optString(0) to range.optString(1))
        }.toMap()
    }
}
