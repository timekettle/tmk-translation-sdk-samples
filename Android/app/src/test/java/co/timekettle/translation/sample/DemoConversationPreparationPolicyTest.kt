package co.timekettle.translation.sample

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DemoConversationPreparationPolicyTest {

    @Test
    fun releasedPageCannotPrepareAnotherRoom() {
        assertFalse(DemoConversationPreparationPolicy.canPrepare(released = true, hasChannel = false))
        assertTrue(DemoConversationPreparationPolicy.canPrepare(released = false, hasChannel = false))
        assertFalse(DemoConversationPreparationPolicy.canPrepare(released = false, hasChannel = true))
    }

    @Test
    fun lifecycleGateAllowsExactlyOneReleasePerPageSession() {
        val gate = DemoConversationLifecycleGate()

        assertFalse(gate.isReleased())
        assertTrue(gate.tryRelease())
        assertTrue(gate.isReleased())
        assertFalse(gate.tryRelease())

        gate.reopen()

        assertFalse(gate.isReleased())
        assertTrue(gate.tryRelease())
        assertFalse(gate.tryRelease())
    }
}
