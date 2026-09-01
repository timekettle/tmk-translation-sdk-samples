package co.timekettle.translation.sample

import android.os.Handler
import android.os.Looper
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
                val text = if (isConnectionRecovery(snapshot)) {
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

    private fun isConnectionRecovery(snapshot: TmkTranslationChannelStateSnapshot): Boolean {
        if (snapshot.reason == TmkTranslationChannelStateReason.NETWORK_RESTORED) return true
        return snapshot.message.startsWith("rtm state=CONNECTED") ||
            snapshot.message.startsWith("rtc reconnected") ||
            snapshot.message.startsWith("rtc rejoin success")
    }
}

internal object DemoRtmReconnectTimeoutStatePolicy {
    fun reconnecting(snapshot: TmkTranslationChannelStateSnapshot): Boolean? {
        if (snapshot.reason == TmkTranslationChannelStateReason.MESSAGE_CHANNEL_FAILURE) {
            if (snapshot.state == TmkTranslationChannelState.RECONNECTING) return true
            if (snapshot.state == TmkTranslationChannelState.FAILED) return false
        }
        if (snapshot.message.startsWith("rtm state=CONNECTED")) {
            return false
        }
        return null
    }
}

internal fun interface DemoReconnectTimeoutTask {
    fun cancel()
}

internal fun interface DemoReconnectTimeoutScheduler {
    fun schedule(delayMs: Long, action: () -> Unit): DemoReconnectTimeoutTask
}

private class DemoMainThreadReconnectTimeoutScheduler : DemoReconnectTimeoutScheduler {
    private val handler = Handler(Looper.getMainLooper())

    override fun schedule(delayMs: Long, action: () -> Unit): DemoReconnectTimeoutTask {
        val runnable = Runnable(action)
        handler.postDelayed(runnable, delayMs)
        return DemoReconnectTimeoutTask { handler.removeCallbacks(runnable) }
    }
}

/** Demo 侧仅观察 RTM 重连；超时提示不会干预 SDK 自身的重连过程。 */
internal class DemoReconnectTimeoutMonitor(
    private val timeoutMs: Long = 60_000L,
    private val scheduler: DemoReconnectTimeoutScheduler = DemoMainThreadReconnectTimeoutScheduler(),
    private val onPromptRequired: () -> Unit,
    private val onPromptDismissRequired: () -> Unit = {},
) {
    private var timeoutTask: DemoReconnectTimeoutTask? = null
    private var isRtmReconnecting = false
    private var isPromptVisible = false

    fun handle(isRtmReconnecting: Boolean) {
        if (isRtmReconnecting) {
            this.isRtmReconnecting = true
            scheduleTimerIfNeeded()
            return
        }

        this.isRtmReconnecting = false
        cancelTimer()
        if (isPromptVisible) {
            isPromptVisible = false
            onPromptDismissRequired()
        }
    }

    fun continueWaiting() {
        if (!isRtmReconnecting) return
        isPromptVisible = false
        cancelTimer()
        scheduleTimerIfNeeded()
    }

    fun confirmRecreation() {
        reset(dismissPrompt = false)
    }

    fun cancel() {
        reset(dismissPrompt = true)
    }

    private fun scheduleTimerIfNeeded() {
        if (!isRtmReconnecting || isPromptVisible || timeoutTask != null) return
        timeoutTask = scheduler.schedule(timeoutMs) {
            timeoutTask = null
            if (!isRtmReconnecting || isPromptVisible) return@schedule
            isPromptVisible = true
            onPromptRequired()
        }
    }

    private fun cancelTimer() {
        timeoutTask?.cancel()
        timeoutTask = null
    }

    private fun reset(dismissPrompt: Boolean) {
        isRtmReconnecting = false
        cancelTimer()
        if (isPromptVisible) {
            isPromptVisible = false
            if (dismissPrompt) onPromptDismissRequired()
        }
    }
}
