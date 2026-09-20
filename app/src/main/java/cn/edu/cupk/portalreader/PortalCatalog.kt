package cn.edu.cupk.portalreader

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
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
    val quick: Boolean = false
) {
    val url: String get() = if (path.startsWith("http")) path else baseUrl.trimEnd('/') + path
}

data class PortalGroup(val title: String, val items: List<PortalItem>)

data class SchoolDefinition(
    val id: String,
    val name: String,
    val baseUrl: String,
    val adapterAsset: String,
    val readerConfigJson: String,
    val fallbackUnitTimes: Map<String, Pair<String, String>>,
    val groups: List<PortalGroup>
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
        val baseUrl = if (BuildConfig.LOCAL_MOCK_ENABLED) PortalConfig.BASE else "${profile.origin}/student"
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
                                quick = item.optBoolean("quick", false)
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
            groups = groups
        )
    }

    fun readAdapterScript(context: Context, assetPath: String): String =
        readConfiguredText(context, assetPath)

    suspend fun refreshFromGitHub(context: Context): Result<SchoolRefreshResult> =
        withContext(Dispatchers.IO) {
            runCatching {
                val appContext = context.applicationContext
                val indexText = PalmAcademicGitHub.repositoryFile("$REMOTE_REPOSITORY_ROOT/$INDEX_ASSET")
                val remoteProfiles = parseProfiles(indexText)
                require(remoteProfiles.isNotEmpty()) { "远程学校列表为空" }

                val downloaded = linkedMapOf<String, String>()
                remoteProfiles.map { it.definitionAsset }.distinct().forEach { definitionPath ->
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
                // Commit the index last so an interrupted refresh keeps using the previous set.
                writeRemoteFile(cacheRoot, INDEX_ASSET, indexText)

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
        val remote = remoteFile(context, INDEX_ASSET)
        if (remote.isFile) {
            runCatching { return parseProfiles(remote.readText()) }
        }
        val bundled = context.assets.open(INDEX_ASSET).bufferedReader().use { it.readText() }
        return parseProfiles(bundled)
    }

    private fun parseProfiles(text: String): List<SchoolProfile> {
        val root = JSONObject(text)
        require(root.optInt("schemaVersion", 0) == 1) { "不支持的学校配置版本" }
        val array = root.getJSONArray("schools")
        return (0 until array.length()).map { index ->
            val item = array.getJSONObject(index)
            val id = item.getString("id")
            val origin = item.getString("origin").trimEnd('/')
            val definitionAsset = item.getString("definitionAsset")
            require(id.matches(Regex("[a-z0-9-]+"))) { "学校 id 格式无效" }
            require(origin.startsWith("https://")) { "学校地址必须使用 HTTPS" }
            requireSafeAssetPath(definitionAsset, "schools/", ".json")
            SchoolProfile(
                id = id,
                name = item.getString("name"),
                origin = origin,
                definitionAsset = definitionAsset,
                readerConfig = item.optJSONObject("readerConfig") ?: JSONObject()
            )
        }.also { parsed -> require(parsed.map { it.id }.distinct().size == parsed.size) { "学校 id 重复" } }
    }

    private fun readJsonConfig(context: Context, assetPath: String): JSONObject {
        val remote = remoteFile(context, assetPath)
        if (remote.isFile) {
            runCatching { return JSONObject(remote.readText()).also(::validateDefinition) }
        }
        return context.assets.open(assetPath).bufferedReader().use { JSONObject(it.readText()) }
    }

    private fun readConfiguredText(context: Context, assetPath: String): String {
        val remote = remoteFile(context, assetPath)
        if (remote.isFile) return remote.readText()
        return context.assets.open(assetPath).bufferedReader().use { it.readText() }
    }

    private fun validateDefinition(root: JSONObject) {
        require(root.optInt("schemaVersion", 0) == 1) { "不支持的学校定义版本" }
        require(root.has("groups")) { "学校定义缺少 groups" }
        requireSafeAssetPath(root.getString("readerAdapter"), "adapters/", ".js")
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
