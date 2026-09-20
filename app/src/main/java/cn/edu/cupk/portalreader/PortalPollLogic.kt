package cn.edu.cupk.portalreader

internal object PortalPollLogic {
    fun courseChanged(
        oldHash: String?,
        oldSemester: String?,
        newHash: String,
        newSemester: String,
        newHasEntries: Boolean
    ): Boolean = oldHash != null && (
        oldHash != newHash ||
            oldSemester != null && oldSemester != newSemester && newHasEntries
        )

    fun contentChanged(previous: String?, current: String): Boolean =
        previous != null && previous != current
}
