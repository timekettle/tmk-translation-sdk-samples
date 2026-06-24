package co.timekettle.translation.sample

internal object OfflineDemoModelReadinessPolicy {
    fun shouldRefreshBeforePreparingChannel(isModelReady: Boolean): Boolean {
        return !isModelReady
    }
}
