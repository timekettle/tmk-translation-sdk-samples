package co.timekettle.translation.sample

import co.timekettle.translation.config.TmkDiagnosisLevel

/** 输入草稿保留空串和非法内容，确认时统一校验，不在键入时截断或静默取默认值。 */
internal data class DemoDiagnosisSettings(
    val capacityInput: String = "500",
    val sessionCountOverride: String? = null,
) {
    val capacityMB: Long? get() = positiveInteger(capacityInput, MAX_CAPACITY_MB)
    val sessionCount: Int? get() = sessionCountOverride?.let { positiveInteger(it, Int.MAX_VALUE.toLong())?.toInt() }
    val valid: Boolean get() = capacityMB != null && (sessionCountOverride == null || sessionCount != null)
    fun displayedSessionCount(level: TmkDiagnosisLevel): String = sessionCountOverride ?: defaultSessionCount(level).toString()

    companion object {
        const val MAX_CAPACITY_MB = Long.MAX_VALUE / (1024L * 1024L)
        fun positiveInteger(raw: String, maximum: Long): Long? = raw.takeIf {
            it.isNotEmpty() && it.all { char -> char in '0'..'9' }
        }?.toLongOrNull()?.takeIf { it in 1..maximum }
        fun defaultSessionCount(level: TmkDiagnosisLevel): Int = when (level) {
            TmkDiagnosisLevel.ESSENTIAL -> 10
            TmkDiagnosisLevel.DIAGNOSTIC -> 50
            TmkDiagnosisLevel.TRACE -> 200
        }
    }
}
