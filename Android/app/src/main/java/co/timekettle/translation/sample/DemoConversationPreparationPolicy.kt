package co.timekettle.translation.sample

import java.util.concurrent.atomic.AtomicBoolean

/** Prevents a stale UI callback from recreating a room after the page is released. */
internal object DemoConversationPreparationPolicy {
    fun canPrepare(released: Boolean, hasChannel: Boolean): Boolean =
        !released && !hasChannel
}

/** 页面会话的一次性释放门闩；合法重建时通过 [reopen] 开启下一轮会话。 */
internal class DemoConversationLifecycleGate(initiallyReleased: Boolean = false) {
    private val released = AtomicBoolean(initiallyReleased)

    fun isReleased(): Boolean = released.get()

    fun tryRelease(): Boolean = released.compareAndSet(false, true)

    fun reopen() {
        released.set(false)
    }
}
