package cn.edu.cupk.portalreader

import android.content.Context
import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream

data class SchoolOption(val id: String, val name: String, val imported: Boolean = false)
data class SchoolRefreshResult(val schoolCount: Int, val downloadedFileCount: Int)
data class SchoolImportResult(val schoolId: String, val schoolName: String)

private data class SchoolProfile(
    val id: String,
    val name: String,
    val origin: String,
    val definitionAsset: String,
    val readerConfig: JSONObject,
    val imported: Boolean = false
)

private data class SchoolIndex(
    val builtIn: List<SchoolProfile>,
    val imported: List<SchoolProfile>,
    val configVersion: Int
) {
    val all: List<SchoolProfile> get() = builtIn + imported
}

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
    val gradePath: String,
    val examPath: String,
    val semesterIdPatterns: List<String>
) {
    fun url(baseUrl: String, path: String): String =
        if (path.startsWith("https://")) path else baseUrl.trimEnd('/') + "/" + path.trimStart('/')

    fun coursePageUrl(baseUrl: String): String = url(baseUrl, coursePagePath)

    fun courseDataUrl(baseUrl: String, semesterId: String): String =
        url(baseUrl, courseDataPathTemplate.replace("{semesterId}", semesterId))

    fun extractSemesterId(page: String): String? = semesterIdPatterns.firstNotNullOfOrNull { pattern ->
        runCatching { Regex(pattern, RegexOption.DOT_MATCHES_ALL) }.getOrNull()
            ?.find(page)?.groupValues?.getOrNull(1)
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
    private const val MAX_LOCAL_RULE_BYTES = 2 * 1024 * 1024
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
        return profiles.map { SchoolOption(it.id, it.name, it.imported) }
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
                            "?bizTypeId=2&semesterId={semesterId}&searchTeachingSyllabus=true"
                    },
                gradePath = monitorJson.optString("gradePath", "/for-std/grade/sheet"),
                examPath = monitorJson.optString("examPath", "/for-std/exam-arrange"),
                semesterIdPatterns = monitorJson.optJSONArray("semesterIdPatterns")?.let { patterns ->
                    (0 until patterns.length()).map(patterns::getString)
                }.orEmpty().ifEmpty {
                    listOf(
                        "currentSemester\\s*=.*?[\"']?id[\"']?\\s*:\\s*(\\d+)",
                        "var\\s+semesterId\\s*=\\s*(\\d+)",
                        "[\"']semesterId[\"']\\s*:\\s*[\"']?(\\d+)"
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
                // 本地导入规则只从 App 私有索引读取。远程 index 中即使出现 imported，
                // 也不能覆盖用户已经导入的规则。
                val localImported = currentIndex(appContext).imported

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
                // Commit the merged index last. Online/App 更新只替换 builtIn，imported 原样保留。
                writeRemoteFile(
                    cacheRoot,
                    INDEX_ASSET,
                    indexJson(SchoolIndex(remoteIndex.builtIn, localImported, remoteIndex.configVersion))
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

    suspend fun importLocalRule(context: Context, uri: Uri): Result<SchoolImportResult> =
        withContext(Dispatchers.IO) {
            runCatching {
                val appContext = context.applicationContext
                val text = appContext.contentResolver.openInputStream(uri)?.use { input ->
                    readLimitedText(input)
                } ?: error("无法读取规则文件")
                val packageRoot = JSONObject(text)
                require(packageRoot.optInt("schemaVersion", 0) == 1) { "不支持的本地规则版本" }
                val profileJson = packageRoot.getJSONObject("profile")
                val definition = packageRoot.getJSONObject("definition")
                val adapterScript = packageRoot.getString("adapterScript")
                require(adapterScript.isNotBlank()) { "适配脚本为空" }

                val schoolId = profileJson.getString("id")
                require(schoolId.matches(Regex("[a-z0-9-]+"))) { "学校 id 格式无效" }
                val existing = currentIndex(appContext)
                require(existing.builtIn.none { it.id == schoolId }) { "不能覆盖内置学校规则" }

                val definitionPath = "schools/imported/$schoolId.json"
                val adapterPath = "adapters/imported/$schoolId-reader.js"
                definition.put("readerAdapter", adapterPath)
                validateDefinition(definition)
                validateFourQuickEntries(definition)

                val profile = parseProfile(
                    JSONObject(profileJson.toString()).put("definitionAsset", definitionPath),
                    imported = true
                )
                val imported = (existing.imported.filterNot { it.id == schoolId } + profile)
                    .sortedBy { it.id }
                val cacheRoot = File(appContext.filesDir, REMOTE_CACHE_DIRECTORY)
                writeRemoteFile(cacheRoot, definitionPath, definition.toString(2))
                writeRemoteFile(cacheRoot, adapterPath, adapterScript)
                writeRemoteFile(
                    cacheRoot,
                    INDEX_ASSET,
                    indexJson(SchoolIndex(existing.builtIn, imported, existing.configVersion))
                )

                profiles = readProfiles(appContext)
                SchoolImportResult(profile.id, profile.name)
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
        return currentIndex(context).all
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
                    SchoolIndex(bundled.builtIn, cachedIndex.imported, bundled.configVersion)
                } else {
                    cachedIndex
                }
            }
        }
        return bundled
    }

    private fun readLimitedText(input: InputStream): String {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8 * 1024)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            require(output.size() + count <= MAX_LOCAL_RULE_BYTES) { "规则文件不能超过 2 MB" }
            output.write(buffer, 0, count)
        }
        return output.toString(Charsets.UTF_8.name())
    }

    private fun parseIndex(text: String): SchoolIndex {
        val root = JSONObject(text)
        val version = root.optInt("schemaVersion", 0)
        val builtInArray: JSONArray
        val importedArray: JSONArray
        when (version) {
            1 -> {
                builtInArray = root.optJSONArray("schools") ?: JSONArray()
                importedArray = JSONArray()
            }
            2 -> {
                builtInArray = root.optJSONArray("builtIn") ?: JSONArray()
                importedArray = root.optJSONArray("imported") ?: JSONArray()
            }
            else -> error("不支持的学校配置版本")
        }
        val builtIn = parseProfileArray(builtInArray, imported = false)
        val imported = parseProfileArray(importedArray, imported = true)
        require((builtIn + imported).map { it.id }.distinct().size == builtIn.size + imported.size) {
            "内置与导入学校 id 重复"
        }
        return SchoolIndex(builtIn, imported, root.optInt("configVersion", 1))
    }

    private fun parseProfileArray(array: JSONArray, imported: Boolean): List<SchoolProfile> =
        (0 until array.length()).map { parseProfile(array.getJSONObject(it), imported) }

    private fun parseProfile(item: JSONObject, imported: Boolean): SchoolProfile {
        val id = item.getString("id")
        val origin = item.getString("origin").trimEnd('/')
        val definitionAsset = item.getString("definitionAsset")
        require(id.matches(Regex("[a-z0-9-]+"))) { "学校 id 格式无效" }
        require(item.getString("name").isNotBlank()) { "学校名称为空" }
        require(origin.startsWith("https://")) { "学校地址必须使用 HTTPS" }
        requireSafeAssetPath(definitionAsset, "schools/", ".json")
        if (imported) require(definitionAsset.startsWith("schools/imported/")) {
            "导入学校定义必须位于 schools/imported/"
        }
        return SchoolProfile(
            id = id,
            name = item.getString("name"),
            origin = origin,
            definitionAsset = definitionAsset,
            readerConfig = item.optJSONObject("readerConfig") ?: JSONObject(),
            imported = imported
        )
    }

    private fun indexJson(index: SchoolIndex): String = JSONObject().apply {
        put("schemaVersion", 2)
        put("configVersion", index.configVersion)
        put("builtIn", JSONArray().apply { index.builtIn.forEach { put(it.toJson()) } })
        put("imported", JSONArray().apply { index.imported.forEach { put(it.toJson()) } })
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
        listOf("coursePagePath", "courseDataPathTemplate", "gradePath", "examPath").forEach { key ->
            val path = monitor.optString(key)
            require(path.startsWith("/") || path.startsWith("https://")) { "monitor.$key 路径无效" }
        }
        require("{semesterId}" in monitor.getString("courseDataPathTemplate")) {
            "monitor.courseDataPathTemplate 缺少 {semesterId}"
        }
        monitor.optJSONArray("semesterIdPatterns")?.let { patterns ->
            require(patterns.length() > 0) { "semesterIdPatterns 不能为空" }
            for (index in 0 until patterns.length()) Regex(patterns.getString(index))
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
