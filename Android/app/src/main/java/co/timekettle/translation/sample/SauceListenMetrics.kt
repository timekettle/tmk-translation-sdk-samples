package co.timekettle.translation.sample

import android.os.SystemClock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

/** Test-audio-only callback evidence, measured on one monotonic device clock. */
internal class SauceListenMetrics {
    private val lock = Any()
    private var inputStartedAtMs: Long? = null
    private var firstAsrMs: Long? = null
    private var firstMtMs: Long? = null
    private var firstAudioCallbackMs: Long? = null
    private var firstTtsPacketMs: Long? = null
    private val asrFinalSegments = mutableListOf<String>()
    private val mtFinalSegments = mutableListOf<String>()
    private val _snapshot = MutableStateFlow(snapshotLocked())
    val snapshot: StateFlow<String> = _snapshot.asStateFlow()

    fun reset() = synchronized(lock) {
        inputStartedAtMs = null
        firstAsrMs = null
        firstMtMs = null
        firstAudioCallbackMs = null
        firstTtsPacketMs = null
        asrFinalSegments.clear()
        mtFinalSegments.clear()
        publishLocked()
    }

    fun markInputStarted() = synchronized(lock) {
        if (inputStartedAtMs == null) {
            inputStartedAtMs = SystemClock.elapsedRealtime()
            publishLocked()
        }
    }

    fun recordAsr(text: String, isFinal: Boolean) = synchronized(lock) {
        if (inputStartedAtMs == null || text.isBlank()) return@synchronized
        if (firstAsrMs == null) firstAsrMs = elapsedLocked()
        if (isFinal) asrFinalSegments.add(text.trim())
        publishLocked()
    }

    fun recordMt(text: String, isFinal: Boolean) = synchronized(lock) {
        if (inputStartedAtMs == null || text.isBlank()) return@synchronized
        if (firstMtMs == null) firstMtMs = elapsedLocked()
        if (isFinal) mtFinalSegments.add(text.trim())
        publishLocked()
    }

    fun recordTtsPacket(data: ByteArray) = synchronized(lock) {
        if (inputStartedAtMs == null || data.isEmpty()) return@synchronized
        var changed = false
        if (firstAudioCallbackMs == null) {
            firstAudioCallbackMs = elapsedLocked()
            changed = true
        }
        if (firstTtsPacketMs == null && containsAudiblePcm16Le(data)) {
            firstTtsPacketMs = elapsedLocked()
            changed = true
        }
        if (changed) publishLocked()
    }

    /** Match L3's PCM16LE audible-sample threshold; silent playback frames are not TTS speech. */
    private fun containsAudiblePcm16Le(data: ByteArray): Boolean {
        var index = 0
        while (index + 1 < data.size) {
            val sample = ((data[index].toInt() and 0xff) or (data[index + 1].toInt() shl 8)).toShort().toInt()
            if (kotlin.math.abs(sample) > 2) return true
            index += 2
        }
        return false
    }

    private fun elapsedLocked(): Long? = inputStartedAtMs?.let { SystemClock.elapsedRealtime() - it }

    private fun publishLocked() {
        _snapshot.value = snapshotLocked()
    }

    private fun snapshotLocked(): String = JSONObject()
        .put("schema_version", 1)
        .put("input_started", inputStartedAtMs != null)
        .put("first_asr_ms", firstAsrMs ?: JSONObject.NULL)
        .put("first_mt_ms", firstMtMs ?: JSONObject.NULL)
        .put("first_audio_callback_ms", firstAudioCallbackMs ?: JSONObject.NULL)
        .put("first_tts_packet_ms", firstTtsPacketMs ?: JSONObject.NULL)
        .put("asr_final_segments", JSONArray(asrFinalSegments))
        .put("mt_final_segments", JSONArray(mtFinalSegments))
        .toString()
}
