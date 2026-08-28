package co.timekettle.translation.sample

import android.media.AudioFormat
import android.media.AudioTrack
import android.util.Log

/**
 * 一对一下行 TTS 队列式播放器(在线/离线一对一 Demo 共用)。
 *
 * 从 [Online1v1ViewModel] 中抽出的队列播放逻辑,对齐 iOS 在线/离线共用的边录边播缓冲:
 * - 单一 [AudioTrack],按帧的真实声道数动态创建(mono/stereo 切换时重建)。
 * - 队列裁剪:堆积超过 [maxQueueMs] 时丢弃旧帧到 [targetQueueMs],避免延迟累积。
 * - 声道数变化时清空队列,避免不同声道数据混播。
 *
 * 线程安全:内部用 [queueLock] 串行化;播放在独立线程。
 */
class OneToOneTtsQueuePlayer(
    private val tag: String,
    private val sampleRate: Int = 16_000,
    private val audioFormat: Int = AudioFormat.ENCODING_PCM_16BIT,
    private val maxQueueMs: Int = 1_000,
    private val targetQueueMs: Int = 300,
) {
    private data class TtsFrame(val data: ByteArray, val sampleRate: Int, val channelCount: Int)

    private val queueLock = Object()
    private val queue = java.util.ArrayDeque<TtsFrame>()
    private var queuedBytes: Int = 0
    private var queuedChannelCount: Int = 0
    private var queuedSampleRate: Int = 0
    private var playerThread: Thread? = null
    @Volatile private var isRunning = false

    private var audioTrack: AudioTrack? = null
    private var audioTrackSampleRate: Int = 0
    private var audioTrackChannelCount: Int = 0

    /** 送一帧 PCM 去播放(拷贝入队)。channelCount 只区分 1/2；sampleRate 变化时重建 AudioTrack。 */
    fun play(data: ByteArray, channelCount: Int, sampleRate: Int = this.sampleRate) {
        if (data.isEmpty()) return
        val safeChannelCount = if (channelCount == 2) 2 else 1
        val safeSampleRate = sampleRate.takeIf { it > 0 } ?: this.sampleRate
        synchronized(queueLock) {
            if ((queuedChannelCount != 0 && queuedChannelCount != safeChannelCount) ||
                (queuedSampleRate != 0 && queuedSampleRate != safeSampleRate)
            ) {
                clearQueueLocked()
            }
            queuedChannelCount = safeChannelCount
            queuedSampleRate = safeSampleRate
            ensurePlayerThreadLocked()
            queue.addLast(TtsFrame(data.copyOf(), safeSampleRate, safeChannelCount))
            queuedBytes += data.size
            trimQueueLocked(safeSampleRate, safeChannelCount)
            queueLock.notifyAll()
        }
    }

    /** 清空待播队列(切换播放音源时调用,丢弃残留的反声道数据)。不停止播放线程。 */
    fun clearQueue() {
        synchronized(queueLock) { clearQueueLocked() }
    }

    /** 停止播放并释放资源。 */
    fun stop() {
        synchronized(queueLock) {
            isRunning = false
            clearQueueLocked()
            queueLock.notifyAll()
        }
        playerThread?.interrupt()
        playerThread = null
        releaseAudioTrack()
    }

    private fun ensurePlayerThreadLocked() {
        if (isRunning && playerThread?.isAlive == true) return
        isRunning = true
        playerThread = Thread({ runPlaybackLoop() }, "$tag-TtsPlayer").apply { start() }
    }

    private fun runPlaybackLoop() {
        while (isRunning) {
            val frame = synchronized(queueLock) {
                while (queue.isEmpty() && isRunning) {
                    try {
                        queueLock.wait()
                    } catch (_: InterruptedException) {
                    }
                }
                if (!isRunning) {
                    null
                } else {
                    val next = queue.removeFirst()
                    queuedBytes -= next.data.size
                    if (queue.isEmpty()) {
                        queuedChannelCount = 0
                        queuedSampleRate = 0
                    }
                    next
                }
            } ?: break

            writeFrame(frame)
        }
    }

    private fun writeFrame(frame: TtsFrame) {
        try {
            val track = ensureAudioTrack(frame.sampleRate, frame.channelCount) ?: return
            var offset = 0
            while (offset < frame.data.size && isRunning) {
                val written = track.write(frame.data, offset, frame.data.size - offset)
                if (written > 0) {
                    offset += written
                } else if (written < 0) {
                    Log.e(tag, "播放 TTS 写入失败: $written")
                    break
                }
            }
        } catch (e: Exception) {
            Log.e(tag, "播放 TTS 异常", e)
        }
    }

    private fun ensureAudioTrack(sampleRate: Int, channelCount: Int): AudioTrack? {
        val existing = audioTrack
        if (existing != null &&
            audioTrackSampleRate == sampleRate &&
            audioTrackChannelCount == channelCount &&
            existing.state != AudioTrack.STATE_UNINITIALIZED
        ) {
            return existing
        }

        releaseAudioTrack()
        val outCh = if (channelCount == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
        val minBufferSize = AudioTrack.getMinBufferSize(sampleRate, outCh, audioFormat).coerceAtLeast(0)
        val bufferSize = maxOf(minBufferSize, bytesForMs(sampleRate, channelCount, 200))
        audioTrack = AudioTrack.Builder()
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(sampleRate)
                    .setChannelMask(outCh)
                    .setEncoding(audioFormat)
                    .build()
            )
            .setBufferSizeInBytes(bufferSize)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        audioTrackSampleRate = sampleRate
        audioTrackChannelCount = channelCount
        audioTrack?.play()
        return audioTrack
    }

    private fun trimQueueLocked(sampleRate: Int, channelCount: Int) {
        val maxBytes = bytesForMs(sampleRate, channelCount, maxQueueMs)
        if (queuedBytes <= maxBytes) return
        val targetBytes = bytesForMs(sampleRate, channelCount, targetQueueMs)
        var droppedBytes = 0
        while (queue.size > 1 && queuedBytes > targetBytes) {
            val dropped = queue.removeFirst()
            queuedBytes -= dropped.data.size
            droppedBytes += dropped.data.size
        }
        if (droppedBytes > 0) {
            Log.w(tag, "TTS 队列过长，丢弃旧音频约 ${durationMs(droppedBytes, sampleRate, channelCount)}ms")
        }
    }

    private fun clearQueueLocked() {
        queue.clear()
        queuedBytes = 0
        queuedChannelCount = 0
        queuedSampleRate = 0
    }

    private fun bytesForMs(sampleRate: Int, channelCount: Int, ms: Int): Int =
        sampleRate * channelCount * PCM_16BIT_BYTES * ms / 1_000

    private fun durationMs(bytes: Int, sampleRate: Int, channelCount: Int): Long {
        val bytesPerSecond = sampleRate * channelCount * PCM_16BIT_BYTES
        return if (bytesPerSecond > 0) bytes * 1_000L / bytesPerSecond else 0L
    }

    private fun releaseAudioTrack() {
        try {
            audioTrack?.pause()
            audioTrack?.flush()
            audioTrack?.stop()
            audioTrack?.release()
        } catch (_: Exception) {
        }
        audioTrack = null
        audioTrackSampleRate = 0
        audioTrackChannelCount = 0
    }

    private companion object {
        private const val PCM_16BIT_BYTES = 2
    }
}
