package cn.edu.cupk.portalreader

import android.content.Context

/** Tracks the four-page warm-up requested by an actual successful login. */
internal object QuickEntryBaseline {
    private const val PREFERENCES = "quick_entry_baseline"
    private const val KEY_PENDING_SCHOOL = "pending_school"
    private const val KEY_LAST_COMPLETED_AT = "last_completed_at"

    fun request(context: Context) {
        context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_PENDING_SCHOOL, SchoolAdapterRepository.activeSchoolId())
            .apply()
    }

    fun isPending(context: Context, schoolId: String): Boolean =
        context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .getString(KEY_PENDING_SCHOOL, null) == schoolId

    fun recordAndComplete(
        context: Context,
        schoolId: String,
        snapshots: List<QuickEntryBaselineSnapshot>
    ) {
        val preferences = context.applicationContext
            .getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        if (preferences.getString(KEY_PENDING_SCHOOL, null) != schoolId) return
        if (snapshots.size != 4) return
        PortalPollHistory.append(
            context.applicationContext,
            PortalPollHistoryEntry(
                timestamp = System.currentTimeMillis(),
                status = "首次登录基线已建立（4 项）",
                notificationTriggered = false,
                details = snapshots.map { snapshot ->
                    PortalPollHistoryDetail(
                        category = quickBaselineCategory(snapshot.item.nativeType),
                        summary = "已建立初始数据",
                        changed = false,
                        notificationTriggered = false,
                        requestUrl = snapshot.item.url,
                        finalUrl = snapshot.page.sourceUrl.ifBlank { snapshot.item.url },
                        technicalDetails = "首次登录后由学校 adapter 后台获取并写入快捷入口缓存。",
                        currentContent = PortalSnapshot.historyDisplayContent(snapshot.rawJson)
                    )
                }
            )
        )
        preferences.edit()
            .remove(KEY_PENDING_SCHOOL)
            .putLong(KEY_LAST_COMPLETED_AT, System.currentTimeMillis())
            .apply()
    }
}

internal data class QuickEntryBaselineSnapshot(
    val item: PortalItem,
    val page: MaterialPage,
    val rawJson: String
)

internal fun quickBaselineCategory(nativeType: String?): String = when (nativeType) {
    "schedule" -> "课表"
    "grade" -> "成绩"
    "exam" -> "考试"
    "program" -> "培养方案"
    else -> "快捷入口"
}

/** Distinguishes a populated adapter publication from its initial DOM skeleton. */
internal fun quickBaselineHasData(page: MaterialPage, nativeType: String?): Boolean = when (nativeType) {
    "schedule" -> page.sections.filterIsInstance<MaterialSection.Schedule>()
        .any { section -> section.days.any { it.lessons.isNotEmpty() } }
    "grade" -> page.sections.any { section ->
        when (section) {
            is MaterialSection.Cards -> section.cards.isNotEmpty()
            is MaterialSection.Table -> section.rows.isNotEmpty()
            is MaterialSection.Stats -> section.items.any { it.value.isNotBlank() && it.value != "--" }
            else -> false
        }
    }
    "exam" -> page.sections.any { section ->
        (section is MaterialSection.Cards && section.cards.isNotEmpty()) ||
            (section is MaterialSection.Table && section.rows.isNotEmpty())
    }
    "program" -> page.sections.filterIsInstance<MaterialSection.Program>().any { section ->
        section.completedCredits.isNotBlank() || section.requiredCredits.isNotBlank() ||
            section.modules.any(::programModuleHasData)
    }
    else -> page.sections.isNotEmpty()
}

private fun programModuleHasData(module: ProgramModule): Boolean =
    module.title.isNotBlank() || module.requirements.isNotEmpty() || module.courses.isNotEmpty() ||
        module.children.any(::programModuleHasData)

internal fun orderedQuickBaselineItems(items: List<PortalItem>): List<PortalItem> =
    listOf("schedule", "grade", "exam", "program").mapNotNull { type ->
        items.firstOrNull { it.quick && it.nativeType == type }
    }
