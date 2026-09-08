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

    /** 每个播放 worker 独占 AudioTrack，stop/start 不会让旧线程访问新 worker 的播放器。 */
    private class AudioTrackOwner {
        var track: AudioTrack? = null
        var sampleRate: Int = 0
        var channelCount: Int = 0
    }

    private data class PlaybackWorker(
        val generation: Long,
        val thread: Thread,
    )

    private val queueLock = Object()
    private val queue = java.util.ArrayDeque<TtsFrame>()
    private var queuedBytes: Int = 0
    private var queuedChannelCount: Int = 0
    private var queuedSampleRate: Int = 0
    /** 每次 stop 或创建 worker 都递增，旧线程只能消费自己的代次。 */
    private var nextWorkerGeneration = 0L
    private var playerWorker: PlaybackWorker? = null
    /** 已被 stop 的 worker；新 worker 先等待其释放独占 AudioTrack，避免旧缓冲音频与新音频重叠。 */
    private val retiredWorkerThreads = java.util.ArrayDeque<Thread>()

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
        val threadToInterrupt = synchronized(queueLock) {
            // 先撤销 worker 所有权，再中断。即使旧线程在 write/wait 后晚醒，也不会重新消费新队列。
            nextWorkerGeneration += 1
            clearQueueLocked()
            queueLock.notifyAll()
            val current = playerWorker
            playerWorker = null
            current?.thread?.let { retiredWorkerThreads.addLast(it) }
            pruneRetiredWorkersLocked()
            current?.thread
        }
        threadToInterrupt?.interrupt()
    }

    private fun ensurePlayerThreadLocked() {
        val current = playerWorker
        if (current?.thread?.isAlive == true) return
        pruneRetiredWorkersLocked()
        val predecessors = retiredWorkerThreads.toList()
        val generation = ++nextWorkerGeneration
        val thread = Thread(
            { runPlaybackLoop(generation, predecessors) },
            "$tag-TtsPlayer",
        ).apply { isDaemon = true }
        playerWorker = PlaybackWorker(generation = generation, thread = thread)
        thread.start()
    }

    private fun runPlaybackLoop(generation: Long, predecessors: List<Thread>) {
        val audioTrackOwner = AudioTrackOwner()
        try {
            // stop 不在主线程阻塞；新 worker 自身等待旧 worker 以确保旧轨道已 flush/release。
            for (predecessor in predecessors) {
                if (predecessor !== Thread.currentThread() && predecessor.isAlive) {
                    try {
                        predecessor.join()
                    } catch (_: InterruptedException) {
                        // 当前 worker 也已被 stop；finally 负责清理，不能让线程异常逃逸。
                        return
                    }
                }
            }
            while (isWorkerActive(generation)) {
                val frame = synchronized(queueLock) {
                    while (queue.isEmpty() && isWorkerActiveLocked(generation)) {
                        try {
                            queueLock.wait()
                        } catch (_: InterruptedException) {
                        }
                    }
                    if (!isWorkerActiveLocked(generation)) {
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

                writeFrame(frame, generation, audioTrackOwner)
            }
        } finally {
            releaseAudioTrack(audioTrackOwner)
            synchronized(queueLock) {
                retiredWorkerThreads.remove(Thread.currentThread())
                if (playerWorker?.generation == generation &&
                    playerWorker?.thread === Thread.currentThread()
                ) {
                    playerWorker = null
                }
                queueLock.notifyAll()
            }
        }
    }

    private fun pruneRetiredWorkersLocked() {
        val iterator = retiredWorkerThreads.iterator()
        while (iterator.hasNext()) {
            if (!iterator.next().isAlive) iterator.remove()
        }
    }

    private fun isWorkerActive(generation: Long): Boolean = synchronized(queueLock) {
        isWorkerActiveLocked(generation)
    }

    private fun isWorkerActiveLocked(generation: Long): Boolean =
        playerWorker?.generation == generation

    private fun writeFrame(frame: TtsFrame, generation: Long, audioTrackOwner: AudioTrackOwner) {
        try {
            if (!isWorkerActive(generation)) return
            val track = ensureAudioTrack(audioTrackOwner, frame.sampleRate, frame.channelCount) ?: return
            var offset = 0
            while (offset < frame.data.size && isWorkerActive(generation)) {
                val written = track.write(
                    frame.data,
                    offset,
                    frame.data.size - offset,
                    AudioTrack.WRITE_NON_BLOCKING,
                )
                if (written > 0) {
                    offset += written
                } else if (written == 0) {
                    // 非阻塞写入的背压点可被 stop 的 interrupt 唤醒；避免整句 PCM 阻塞取消。
                    try {
                        Thread.sleep(5L)
                    } catch (_: InterruptedException) {
                        break
                    }
                } else if (written < 0) {
                    Log.e(tag, "播放 TTS 写入失败: $written")
                    break
                }
            }
        } catch (e: Exception) {
            Log.e(tag, "播放 TTS 异常", e)
        }
    }

    private fun ensureAudioTrack(
        owner: AudioTrackOwner,
        sampleRate: Int,
        channelCount: Int,
    ): AudioTrack? {
        val existing = owner.track
        if (existing != null &&
            owner.sampleRate == sampleRate &&
            owner.channelCount == channelCount &&
            existing.state != AudioTrack.STATE_UNINITIALIZED
        ) {
            return existing
        }

        releaseAudioTrack(owner)
        val outCh = if (channelCount == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
        val minBufferSize = AudioTrack.getMinBufferSize(sampleRate, outCh, audioFormat).coerceAtLeast(0)
        val bufferSize = maxOf(minBufferSize, bytesForMs(sampleRate, channelCount, 200))
        owner.track = AudioTrack.Builder()
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
        owner.sampleRate = sampleRate
        owner.channelCount = channelCount
        owner.track?.play()
        return owner.track
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

    private fun releaseAudioTrack(owner: AudioTrackOwner) {
        try {
            owner.track?.pause()
            owner.track?.flush()
            owner.track?.stop()
            owner.track?.release()
        } catch (_: Exception) {
        }
        owner.track = null
        owner.sampleRate = 0
        owner.channelCount = 0
    }

    private companion object {
        private const val PCM_16BIT_BYTES = 2
    }
}
