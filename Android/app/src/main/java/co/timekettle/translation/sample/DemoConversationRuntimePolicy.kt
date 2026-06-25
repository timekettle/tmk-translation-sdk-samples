package co.timekettle.translation.sample

import co.timekettle.translation.model.TmkTranslationChannelState
import co.timekettle.translation.model.TmkTranslationChannelStateReason
import co.timekettle.translation.model.TmkTranslationChannelStateSnapshot

sealed class DemoConversationRuntimeAction {
    data object None : DemoConversationRuntimeAction()
    data object Ignore : DemoConversationRuntimeAction()
    data class Status(val text: String) : DemoConversationRuntimeAction()
    data class WeakNetwork(val text: String) : DemoConversationRuntimeAction()
    data class Reconnecting(val text: String) : DemoConversationRuntimeAction()
}

object DemoConversationRuntimePolicy {
    private const val DEFAULT_READY_MESSAGE = "在线通道已就绪，点击“开始收听”开始采集"

    fun action(
        snapshot: TmkTranslationChannelStateSnapshot,
        readyMessage: String = DEFAULT_READY_MESSAGE,
    ): DemoConversationRuntimeAction {
        return when (snapshot.state) {
            TmkTranslationChannelState.IDLE -> DemoConversationRuntimeAction.Status("通道未启动")
            TmkTranslationChannelState.STARTING -> DemoConversationRuntimeAction.Status("通道连接中...")
            TmkTranslationChannelState.RUNNING -> {
                val text = if (snapshot.reason == TmkTranslationChannelStateReason.NETWORK_RESTORED) {
                    "连接已恢复"
                } else {
                    readyMessage
                }
                DemoConversationRuntimeAction.Status(text)
            }
            TmkTranslationChannelState.DEGRADED -> DemoConversationRuntimeAction.WeakNetwork("当前网络不稳定，翻译可能延迟")
            TmkTranslationChannelState.RECONNECTING -> DemoConversationRuntimeAction.Reconnecting("连接恢复中...")
            TmkTranslationChannelState.STOPPING -> DemoConversationRuntimeAction.Status("通道停止中...")
            TmkTranslationChannelState.STOPPED -> DemoConversationRuntimeAction.Status("通道已停止")
            TmkTranslationChannelState.FAILED -> DemoConversationRuntimeAction.Status(
                "通道异常: ${snapshot.message}"
            )
        }
    }
}
