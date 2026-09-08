package co.timekettle.translation.sample

import co.timekettle.translation.model.TmkTranslationChannelState

/**
 * Demo 层重连超时计时器：SDK 只输出真实链路状态，超时交互由页面自行决定。
 *
 * 计时器不持有 ViewModel 或页面引用；调用方在页面销毁时必须调用 [cancel]。
 */
internal class DemoReconnectTimeoutMonitor(
    private val schedule: (Long, () -> Unit) -> Unit,
    private val cancelScheduled: () -> Unit,
    private val timeoutMs: Long = DEFAULT_TIMEOUT_MS,
) {
    private var reconnecting = false

    fun onStateChanged(state: TmkTranslationChannelState, onTimeout: () -> Unit) {
        if (state == TmkTranslationChannelState.RECONNECTING) {
            if (reconnecting) return
            reconnecting = true
            schedule(timeoutMs) {
                if (reconnecting) onTimeout()
            }
            return
        }
        reconnecting = false
        cancelScheduled()
    }

    /** 用户选择继续等待时，从当前时刻重新开始一个完整观察窗口。 */
    fun continueWaiting(onTimeout: () -> Unit) {
        if (!reconnecting) return
        cancelScheduled()
        schedule(timeoutMs) {
            if (reconnecting) onTimeout()
        }
    }

    fun cancel() {
        reconnecting = false
        cancelScheduled()
    }

    companion object {
        const val DEFAULT_TIMEOUT_MS = 60_000L
    }
}
