package co.timekettle.translation.sample

import co.timekettle.translation.*

internal object OfflineDemoModelReadinessPolicy {
    fun shouldRefreshBeforePreparingChannel(isModelReady: Boolean): Boolean {
        return !isModelReady
    }
}
