package co.timekettle.translation.sample

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OfflineDemoModelReadinessPolicyTest {

    @Test
    fun `skip refresh before prepare when model was just confirmed ready`() {
        assertFalse(OfflineDemoModelReadinessPolicy.shouldRefreshBeforePreparingChannel(isModelReady = true))
    }

    @Test
    fun `refresh before prepare when model readiness is not confirmed`() {
        assertTrue(OfflineDemoModelReadinessPolicy.shouldRefreshBeforePreparingChannel(isModelReady = false))
    }
}
