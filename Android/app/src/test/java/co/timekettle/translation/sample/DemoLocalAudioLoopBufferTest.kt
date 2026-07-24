package co.timekettle.translation.sample

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DemoLocalAudioLoopBufferTest {
    @Test
    fun nextLoopChunk_insertsSilenceForRestartDelayAfterPcmEnds() {
        val buffer = DemoLocalAudioLoopBuffer(
            pcmData = byteArrayOf(1, 2, 3, 4, 5, 6),
            restartDelayMs = 3_000L,
        )

        val first = buffer.nextLoopChunk(expectedLength = 4, nowMs = 1_000L)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), first.data)
        assertTrue(first.startsNewCycle)

        val tail = buffer.nextLoopChunk(expectedLength = 4, nowMs = 1_020L)
        assertArrayEquals(byteArrayOf(5, 6, 0, 0), tail.data)
        assertFalse(tail.startsNewCycle)

        val waiting = buffer.nextLoopChunk(expectedLength = 4, nowMs = 2_000L)
        assertArrayEquals(byteArrayOf(0, 0, 0, 0), waiting.data)
        assertFalse(waiting.startsNewCycle)

        val restarted = buffer.nextLoopChunk(expectedLength = 4, nowMs = 4_020L)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), restarted.data)
        assertTrue(restarted.startsNewCycle)
    }

    @Test
    fun nextLoopChunk_returnsSilenceWhenPcmIsMissing() {
        val buffer = DemoLocalAudioLoopBuffer(pcmData = null)

        val chunk = buffer.nextLoopChunk(expectedLength = 4, nowMs = 1_000L)

        assertArrayEquals(byteArrayOf(0, 0, 0, 0), chunk.data)
        assertFalse(chunk.startsNewCycle)
    }

    @Test
    fun fillNextLoopChunk_returnsTrueOnlyWhenNewCycleStarts() {
        val buffer = DemoLocalAudioLoopBuffer(
            pcmData = byteArrayOf(1, 2, 3, 4),
            restartDelayMs = 3_000L,
        )
        val destination = ByteArray(4)

        val firstCycle = buffer.fillNextLoopChunk(destination, nowMs = 1_000L)
        assertTrue(firstCycle)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), destination)

        val waiting = buffer.fillNextLoopChunk(destination, nowMs = 2_000L)
        assertFalse(waiting)
        assertArrayEquals(byteArrayOf(0, 0, 0, 0), destination)

        val restarted = buffer.fillNextLoopChunk(destination, nowMs = 4_000L)
        assertTrue(restarted)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), destination)
    }
}
