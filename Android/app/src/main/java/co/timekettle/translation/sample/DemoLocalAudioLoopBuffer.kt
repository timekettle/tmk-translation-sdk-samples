package co.timekettle.translation.sample

data class DemoLocalAudioLoopChunk(
    val data: ByteArray,
    val startsNewCycle: Boolean,
)

class DemoLocalAudioLoopBuffer(
    private val pcmData: ByteArray?,
    private val restartDelayMs: Long = DEFAULT_RESTART_DELAY_MS,
) {
    companion object {
        const val DEFAULT_RESTART_DELAY_MS = 3_000L
    }

    private var offset = 0
    private var loopResumeAtMs: Long? = null

    fun reset() {
        offset = 0
        loopResumeAtMs = null
    }

    fun nextLoopChunk(
        expectedLength: Int,
        nowMs: Long = System.currentTimeMillis(),
    ): DemoLocalAudioLoopChunk {
        if (expectedLength <= 0) {
            return DemoLocalAudioLoopChunk(ByteArray(0), startsNewCycle = false)
        }
        val data = ByteArray(expectedLength)
        val startsNewCycle = fillNextLoopChunk(data, nowMs)
        return DemoLocalAudioLoopChunk(data, startsNewCycle)
    }

    fun fillNextLoopChunk(
        destination: ByteArray,
        nowMs: Long = System.currentTimeMillis(),
    ): Boolean {
        if (destination.isEmpty()) return false
        val source = pcmData
        if (source == null || source.isEmpty()) {
            destination.fill(0)
            return false
        }

        loopResumeAtMs?.let { resumeAt ->
            if (nowMs < resumeAt) {
                destination.fill(0)
                return false
            }
            loopResumeAtMs = null
            offset = 0
        }

        val startsNewCycle = offset == 0
        var writeOffset = 0
        while (writeOffset < destination.size) {
            if (offset >= source.size) {
                loopResumeAtMs = nowMs + restartDelayMs
                break
            }
            val available = minOf(destination.size - writeOffset, source.size - offset)
            source.copyInto(
                destination = destination,
                destinationOffset = writeOffset,
                startIndex = offset,
                endIndex = offset + available,
            )
            writeOffset += available
            offset += available
            if (offset >= source.size) {
                loopResumeAtMs = nowMs + restartDelayMs
                break
            }
        }

        if (writeOffset < destination.size) {
            destination.fill(0, writeOffset, destination.size)
        }
        return startsNewCycle && writeOffset > 0
    }
}
