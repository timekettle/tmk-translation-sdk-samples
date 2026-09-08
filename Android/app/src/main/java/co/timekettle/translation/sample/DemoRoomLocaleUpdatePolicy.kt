package co.timekettle.translation.sample

import co.timekettle.translation.model.TmkTranslationChannelState

internal enum class DemoRoomLocaleUpdateAction {
    SUBMIT,
    QUEUE_UNTIL_READY,
    QUEUE_LATEST,
    REJECT,
}

/**
 * Decides how the online-listen Demo handles a locale change once room and channel objects exist.
 *
 * Runtime reconnecting is still an active session: submit the request immediately so the SDK's
 * operation timeout starts at the user's action instead of deferring the request until recovery.
 */
internal object DemoRoomLocaleUpdatePolicy {
    fun action(
        state: TmkTranslationChannelState,
        requestInFlight: Boolean,
    ): DemoRoomLocaleUpdateAction {
        return when (state) {
            TmkTranslationChannelState.IDLE,
            TmkTranslationChannelState.STARTING -> DemoRoomLocaleUpdateAction.QUEUE_UNTIL_READY

            TmkTranslationChannelState.RUNNING,
            TmkTranslationChannelState.DEGRADED,
            TmkTranslationChannelState.RECONNECTING -> {
                if (requestInFlight) {
                    DemoRoomLocaleUpdateAction.QUEUE_LATEST
                } else {
                    DemoRoomLocaleUpdateAction.SUBMIT
                }
            }

            TmkTranslationChannelState.STOPPING,
            TmkTranslationChannelState.STOPPED,
            TmkTranslationChannelState.FAILED -> DemoRoomLocaleUpdateAction.REJECT
        }
    }
}
